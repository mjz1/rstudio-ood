# frozen_string_literal: true
#
# Render the ERB templates the way Open OnDemand renders them, and assert on what
# comes out.
#
# The templates are the least testable and most dangerous part of this app: they
# run inside the PUN, on a machine we do not have, and a mistake in them is not a
# stack trace but a session that fails to launch. CI used to check only that the
# embedded ruby *parsed*, which catches a stray `end` and nothing else -- not a
# nil method call, not a bad path, not a bind that vanished, not a GPU flag
# emitted for a CPU job.
#
# So: build a fixture cluster on disk (images, libraries, config), reproduce
# OnDemand's binding (`context` for script.sh.erb, bare locals for
# submit.yml.erb), render, and check the result. Everything runs against $TMPDIR
# -- no cluster, no Slurm, no real config.
#
# Run via test/run.sh, which supplies ruby (from a container if the host has none).

require 'erb'
require 'yaml'
require 'json'
require 'fileutils'
require 'ostruct'
require 'tmpdir'

APP  = File.expand_path('..', __dir__)
OUT  = ENV.fetch('ERB_TEST_OUT')          # rendered files land here for bash -n
FAIL = []
PASS = []

def check(name)
  ok = yield
  (ok ? PASS : FAIL) << name
  puts(format('  %-4s %s', ok ? 'ok' : 'FAIL', name))
rescue StandardError => e
  FAIL << name
  puts(format('  %-4s %s', 'FAIL', name))
  puts("       #{e.class}: #{e.message}")
  puts("       #{e.backtrace.grep(/erb|\(erb\)/).first(3).join("\n       ")}")
end

def render(path, bind)
  ERB.new(File.read(path), trim_mode: '-').result(bind)
end

# OnDemand hands script.sh.erb a `context` object carrying the form fields. Only
# the fields the user actually submitted respond to respond_to?, which the
# template relies on -- OpenStruct reproduces that exactly.
def context_for(**fields)
  OpenStruct.new(**fields)
end

# submit.yml.erb sees the form fields as BARE LOCALS, not through `context`, and
# guards them with defined?(). A binding with locals injected reproduces both --
# including the case where a field is absent, so defined?() is nil.
def locals_binding(**vars)
  b = binding.dup
  vars.each { |k, v| b.local_variable_set(k, v) }
  b
end

# ---------------------------------------------------------------- the fixture --
#
# A cluster that does not exist: three images but only two package libraries, so
# the form is forced to demonstrate that it drops the version whose library is
# missing (R silently ignores a bad R_LIBS_USER -- this is the check that the app
# never offers you one).

FIX = Dir.mktmpdir('rstudio-erb-fixture')
at_exit { FileUtils.remove_entry(FIX) if File.directory?(FIX) }

IMAGES = File.join(FIX, 'images')
LIBS   = File.join(FIX, 'Rlibs')
WORK   = File.join(FIX, 'work')
DATA   = File.join(FIX, 'data')          # stands in for a site's /data1
FileUtils.mkdir_p([IMAGES, LIBS, WORK, DATA])

%w[4.4 4.5 4.6].each { |v| FileUtils.touch(File.join(IMAGES, "rstudio-#{v}.sif")) }
%w[4.5 4.6].each     { |v| FileUtils.mkdir_p(File.join(LIBS, "#{v}_singularity")) }  # NB: no 4.4

# A slot directory with YAML-hostile characters. The app sanitises slot names it
# CREATES, but the dropdown lists whatever sits in the directory -- and anything
# can mkdir there. One such name must not take down the whole form.
HOSTILE_SLOT = 'evil" ] , [ "x'
FileUtils.mkdir_p(File.join(WORK, '.rstudio-sessions', HOSTILE_SLOT))

File.write(File.join(IMAGES, 'images.json'), JSON.pretty_generate(
  [{ 'r_version' => '4.6', 'r_full' => '4.6.1', 'rstudio' => '2026.06.0+242' },
   { 'r_version' => '4.5', 'r_full' => '4.5.2', 'rstudio' => '2026.06.0+242' },
   { 'r_version' => '4.4', 'r_full' => '4.4.3', 'rstudio' => '2025.09.2' }]
))

# Note the label separators: " · ", never commas. Commas delimit entries in
# RSTUDIO_QUEUES, so a comma inside a label would split it into two bogus queues.
# The templates read `ENV[key] || config[key] || default`, so any RSTUDIO_* left in
# the environment SHADOWS the fixture -- and the person running the tests almost
# certainly has a real config exported by conf.sh. Left alone, this suite reads
# the developer's own cluster (their image directory, their partitions), passes
# for reasons that have nothing to do with the fixture, and behaves differently in
# CI, where none of it is set. Scrub first.
ENV.keys.grep(/\A(RSTUDIO_|R_LIBS_)/).each { |k| ENV.delete(k) }

CONFIG = File.join(FIX, 'config')
File.write(CONFIG, <<~CONF)
  RSTUDIO_IMAGE_DIR=#{IMAGES}
  R_LIBS_ROOT=#{LIBS}
  RSTUDIO_WORK_DIR=#{WORK}
  RSTUDIO_BIND_PATHS=#{DATA},/etc/slurm
  RSTUDIO_CLUSTER=testcluster
  RSTUDIO_QUEUE=componc_cpu
  RSTUDIO_QUEUES=componc_cpu|componc_cpu — CPU · <=7d,componc_gpu_int|componc_gpu_int — GPU H100/H200 · <=1d · interactive
  RSTUDIO_SINGULARITY=singularity
CONF
ENV['RSTUDIO_DEV_CONFIG'] = CONFIG

puts "fixture: #{FIX}"
puts

# ------------------------------------------------------------- form.yml.erb --

puts 'form.yml.erb'
form_src = render(File.join(APP, 'form.yml.erb'), binding)
File.write(File.join(OUT, 'form.yml'), form_src)
form = YAML.safe_load(form_src, aliases: true)

check('renders valid YAML') { form.is_a?(Hash) }
check('cluster comes from config, not a hard-coded default') { form['cluster'] == 'testcluster' }

images = form.dig('attributes', 'rstudio_image', 'options') || []
labels = images.map(&:first)
values = images.map(&:last)
check('offers the images that have a package library (4.6, 4.5)') do
  values.any? { |v| v.end_with?('rstudio-4.6.sif') } &&
    values.any? { |v| v.end_with?('rstudio-4.5.sif') }
end
check('DROPS R 4.4: it has an image but no library (a silent R_LIBS_USER loss)') do
  values.none? { |v| v.to_s.end_with?('rstudio-4.4.sif') }
end
check('labels images from images.json (R 4.6.1 · RStudio ...)') do
  labels.any? { |l| l.include?('4.6.1') && l.include?('2026.06.0') }
end

queues = form.dig('attributes', 'queue', 'options') || []
check('queue dropdown has one entry per configured partition') { queues.length == 2 }
check('queue LABEL is the human string, queue VALUE is the bare partition') do
  queues.include?(['componc_gpu_int — GPU H100/H200 · <=1d · interactive', 'componc_gpu_int'])
end
check('a "·" inside a label does not split the entry (commas are the delimiter)') do
  queues.map(&:last).sort == %w[componc_cpu componc_gpu_int]
end
check('session slot dropdown always offers "default"') do
  (form.dig('attributes', 'session_name', 'options') || []).map(&:last).include?('default')
end
check('survives a PUN with no squeue on PATH (running-slot annotation is advisory)') do
  form.dig('attributes', 'session_name', 'options').is_a?(Array)
end
check('a slot directory with quotes in its name does not break the form YAML') do
  # The strongest evidence is that YAML.safe_load succeeded above WITH the
  # hostile directory present; also confirm the entry round-tripped intact.
  form.dig('attributes', 'session_name', 'options').map(&:last).include?(HOSTILE_SLOT)
end

# ------------------------------------------------------ template/script.sh.erb --

puts
puts 'template/script.sh.erb'
script_erb = File.join(APP, 'template', 'script.sh.erb')

sh = render(script_erb, context_for(
  rstudio_image: File.join(IMAGES, 'rstudio-4.5.sif'),
  session_name: 'default', new_session_name: ''
).instance_eval { context = self; binding })
File.write(File.join(OUT, 'script.sh'), sh)

check('R_LIBS_USER is derived from the SELECTED image (4.5 image -> 4.5 library)') do
  sh.include?("export R_LIBS_USER=\"#{File.join(LIBS, '4.5_singularity')}\"")
end
check('never points at another R minor version library') { !sh.include?('4.6_singularity') }
check('session slot lives under RSTUDIO_WORK_DIR, not a hard-coded ~/work') do
  sh.include?("RSTUDIO_WORK_DIR=\"#{WORK}\"") && sh.include?('SLOT_DIR="${RSTUDIO_WORK_DIR}/.rstudio-sessions/')
end
check('renv cache (XDG_CACHE_HOME) stays SHARED, not per-slot') do
  sh.include?('export XDG_CACHE_HOME="${SHARED_CACHE}"') && sh.include?('SHARED_CACHE="${RSTUDIO_WORK_DIR}/.cache"')
end
check('binds come from RSTUDIO_BIND_PATHS') { sh.include?("'#{DATA}'") && sh.include?("'/etc/slurm'") }
check('no site-specific /data1 left hard-coded in the singularity call') do
  sh.each_line.none? { |l| l.include?('-B') && l.include?('/data1') }
end
check('missing bind paths are skipped, not fatal') { sh.include?('bind path not present on this node, skipping') }
check('idle-suspend is disabled (dedicated allocation; suspension only races renv)') do
  sh.include?('session-timeout-minutes=0') &&
    sh.include?('rsession.conf:/etc/rstudio/rsession.conf')
end
check('the bound rsession.conf MERGES the image copy (bind masks it; overwrite kills copilot)') do
  sh.include?('cat /etc/rstudio/rsession.conf') && sh.include?('>> "${TMPDIR}/rsession.conf"')
end
check('system-default prefs: no .RData save/restore, start in the work dir') do
  sh.include?('"save_workspace": "never"') &&
    sh.include?('"load_workspace": false') &&
    sh.include?('"initial_working_directory": "${RSTUDIO_WORK_DIR}"') &&
    sh.include?('"default_project_location": "${RSTUDIO_WORK_DIR}"') &&
    sh.include?('export XDG_CONFIG_DIRS="/tmp/xdg:/etc/xdg"')
end
check('the auth window outlasts the longest partition (7d = 10080 min)') do
  sh.include?('--auth-timeout-minutes=10080')
end
check('GPU: --nv is gated on Slurm granting a GPU, never on /dev/nvidia*') do
  # Comments are stripped first: the template *explains* at length why it does not
  # probe /dev/nvidia*, and a naive substring match hits that explanation.
  code = sh.each_line.reject { |l| l.strip.start_with?('#') }.join
  code.include?('CUDA_VISIBLE_DEVICES') && code.include?('SLURM_JOB_GPUS') && !code.include?('/dev/nvidia')
end

# The slot becomes a path component. It must not be able to escape the sessions
# root, whatever the user types into the form.
evil = render(script_erb, context_for(
  rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
  session_name: 'default', new_session_name: '../../../etc/cron.d/x'
).instance_eval { context = self; binding })
check('a traversal in the session name is sanitised to one path segment') do
  slot = evil[/SESSION_SLOT="([^"]*)"/, 1]
  !slot.include?('/') && !slot.start_with?('.') && !slot.empty?
end

named = render(script_erb, context_for(
  rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
  session_name: 'old-slot', new_session_name: 'my-project'
).instance_eval { context = self; binding })
check('a new session name overrides the resumed one') { named.include?('SESSION_SLOT="my-project"') }

blank = render(script_erb, context_for(
  rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
  session_name: 'old-slot', new_session_name: '   '
).instance_eval { context = self; binding })
check('a blank new name falls back to the resumed slot') { blank.include?('SESSION_SLOT="old-slot"') }

check('launching the "none available" placeholder fails with an explanation, not a backtrace') do
  begin
    render(script_erb, context_for(
      rstudio_image: '', session_name: 'default', new_session_name: ''
    ).instance_eval { context = self; binding })
    false                                    # rendering must not succeed
  rescue RuntimeError => e
    e.message.include?('sync-images.sh')     # our message, not Errno::ENOENT
  end
end

# ------------------------------------------------------------ submit.yml.erb --

puts
puts 'submit.yml.erb'
submit_erb = File.join(APP, 'submit.yml.erb')

cpu = render(submit_erb, locals_binding(
  queue: 'componc_cpu', num_cores: 8, memory: 16, num_hours: 4,
  num_gpus: 0, session_name: 'default', new_session_name: ''
))
File.write(File.join(OUT, 'submit.yml'), cpu)
cpu_yaml = YAML.safe_load(cpu)
native = cpu_yaml.dig('script', 'native').map(&:to_s)

check('renders valid YAML') { cpu_yaml.is_a?(Hash) }
check('CPU job: no --gres is emitted') { !native.include?('--gres') }
check('job is named after the slot, so squeue distinguishes sessions') do
  native.include?('rstudio-default')
end

gpu = render(submit_erb, locals_binding(
  queue: 'componc_gpu_int', num_cores: 8, memory: 16, num_hours: 4,
  num_gpus: 2, session_name: 'default', new_session_name: 'gpu-work'
))
gpu_native = YAML.safe_load(gpu).dig('script', 'native').map(&:to_s)
check('GPU job: --gres gpu:2 is emitted') do
  i = gpu_native.index('--gres')
  i && gpu_native[i + 1] == 'gpu:2'
end
check('job name follows the new session name') { gpu_native.include?('rstudio-gpu-work') }

# num_gpus arrives as a STRING from the form, and once crashed the template by
# being nil. Both must survive.
str = render(submit_erb, locals_binding(
  queue: 'componc_gpu_int', num_cores: 8, memory: 16, num_hours: 4,
  num_gpus: '3', session_name: 'default', new_session_name: ''
))
check('num_gpus as a string ("3") still produces gpu:3') do
  YAML.safe_load(str).dig('script', 'native').map(&:to_s).include?('gpu:3')
end

absent = render(submit_erb, locals_binding(
  queue: 'componc_cpu', num_cores: 8, memory: 16, num_hours: 4,
  session_name: 'default', new_session_name: ''
))
check('an ABSENT num_gpus does not crash the template (defined? guard)') do
  !YAML.safe_load(absent).dig('script', 'native').map(&:to_s).include?('--gres')
end

# ------------------------------------------------------------- view.html.erb --
#
# The session card. Rendered with the connection params OnDemand persists in
# connection.yml -- host, port, password, csrf_token -- as bare locals.

puts
puts 'view.html.erb'
view = render(File.join(APP, 'view.html.erb'), locals_binding(
  host: 'node042', port: 61234,
  password: 'S3cretPerSession', csrf_token: 'abcd-1234'
))
File.write(File.join(OUT, 'view.html'), view)

check('renders, and posts to RStudio sign-in on the session node') do
  view.include?('action="/rnode/node042/61234/auth-do-sign-in"')
end
check('the Connect button submits the per-session password') do
  view.include?('name="password" value="S3cretPerSession"')
end
check('the password is NEVER the literal string "password"') do
  # The regression that let any cluster user into any session. before.sh.erb is
  # the source of truth, so assert on it directly rather than on a rendered value
  # the test itself supplied.
  before = File.read(File.join(APP, 'template', 'before.sh.erb'))
  before.include?('create_passwd') && !before.match?(/^\s*password=password\s*$/)
end
check('a locked-out user can SEE the credentials (else they hard-code the password)') do
  view.include?('S3cretPerSession') && view.downcase.include?('signed out')
end

# The slot travels job -> connection.yml -> card via conn_params. Three parties
# must agree: submit.yml.erb declares it, before.sh.erb assigns it, the view
# shows it -- and cards of sessions that PREDATE the param must still render.
check('submit.yml declares session_slot as a conn param') do
  YAML.safe_load(cpu).dig('batch_connect', 'conn_params').include?('session_slot')
end
check('before.sh assigns the sanitised slot for connection.yml to capture') do
  before = render(File.join(APP, 'template', 'before.sh.erb'), context_for(
    session_name: 'default', new_session_name: 'my proj!'
  ).instance_eval { context = self; binding })
  before.include?('session_slot="my_proj_"')
end
check('the card names its slot') do
  with_slot = render(File.join(APP, 'view.html.erb'), locals_binding(
    host: 'n1', port: 1, password: 'x', csrf_token: 'y', session_slot: 'aml'
  ))
  with_slot.include?('<code>aml</code>')
end
check('a pre-existing session with no session_slot still renders its card') do
  render(File.join(APP, 'view.html.erb'), locals_binding(
    host: 'n1', port: 1, password: 'x', csrf_token: 'y'
  )).include?('auth-do-sign-in')
end

# ---------------------------------------------------------------------- done --

puts
puts "#{PASS.length} passed, #{FAIL.length} failed"
unless FAIL.empty?
  puts
  puts 'FAILED:'
  FAIL.each { |f| puts "  - #{f}" }
  exit 1
end
