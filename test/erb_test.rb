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

# A slot CREATED three days ago but USED an hour ago: state is written deep
# inside (data/rstudio/...), which never moves the top-level directory's mtime.
# Reading the slot dir alone reports "last used 3d ago" for an active slot.
STALE_MTIME_SLOT = 'used-recently'
_srs = File.join(WORK, '.rstudio-sessions', STALE_MTIME_SLOT)
FileUtils.mkdir_p(File.join(_srs, 'data', 'rstudio', 'sessions'))
_now = Time.now
File.utime(_now - 3600, _now - 3600, File.join(_srs, 'data', 'rstudio', 'sessions'))
File.utime(_now - 3600, _now - 3600, File.join(_srs, 'data', 'rstudio'))
File.utime(_now - 3600, _now - 3600, File.join(_srs, 'data'))
File.utime(_now - 3 * 86_400, _now - 3 * 86_400, _srs)   # dir itself: 3 days old

# An unambiguously stale slot, to sort against.
OLD_SLOT = 'long-abandoned'
_old = File.join(WORK, '.rstudio-sessions', OLD_SLOT)
FileUtils.mkdir_p(File.join(_old, 'data'))
File.utime(_now - 30 * 86_400, _now - 30 * 86_400, File.join(_old, 'data'))
File.utime(_now - 30 * 86_400, _now - 30 * 86_400, _old)

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

# A deployed app dir with a STALE version stamp, for the update-notice check.
APPDIR = File.join(FIX, 'app')
FileUtils.mkdir_p(APPDIR)
File.write(File.join(APPDIR, '.deployed-version'), "0.9.0 abc1234 2026-01-01\n")

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
  RSTUDIO_APP_DIR=#{APPDIR}
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
check('"last used" reflects real activity, not when the slot dir was created') do
  opts = form.dig('attributes', 'session_name', 'options')
  label = opts.find { |_, v| v == STALE_MTIME_SLOT }&.first.to_s
  # Used an hour ago, created three days ago -> must read hours, never days.
  label.include?('h ago') && !label.include?('d ago')
end
check('slots sort by real last-use, so a recently used slot outranks an abandoned one') do
  opts = form.dig('attributes', 'session_name', 'options').map(&:last)
  opts.index(STALE_MTIME_SLOT) < opts.index(OLD_SLOT)
end
check('a slot directory with quotes in its name does not break the form YAML') do
  # The strongest evidence is that YAML.safe_load succeeded above WITH the
  # hostile directory present; also confirm the entry round-tripped intact.
  form.dig('attributes', 'session_name', 'options').map(&:last).include?(HOSTILE_SLOT)
end
check('AI agent access is a three-way select defaulting to Off') do
  a = form.dig('attributes', 'agent_access')
  a && a['value'] == 'off' &&
    (a['options'] || []).map(&:last).sort == %w[execute off read]
end

# The form must show the notice when a session has cached one. Rendered with HOME
# redirected so the fixture's cache file is the one it finds.
check('the launch form shows an update notice when one is cached') do
  fake_home = File.join(FIX, 'home')
  FileUtils.mkdir_p(File.join(fake_home, '.config', 'rstudio_dev'))
  File.write(File.join(fake_home, '.config', 'rstudio_dev', 'update-notice'), "1.2.3\n0.9.0\n")
  real_home = ENV['HOME']
  begin
    ENV['HOME'] = fake_home
    out = render(File.join(APP, 'form.yml.erb'), binding)
    y = YAML.safe_load(out, aliases: true)
    help = y.dig('attributes', 'session_name', 'help').to_s
    y.dig('attributes', 'session_name', 'label').to_s.include?('UPDATE AVAILABLE') &&
      help.include?('0.9.0 → 1.2.3') &&
      help.include?('CHANGELOG.md') &&                        # a link, so users can decide
      help.include?('target="_blank"') &&                     # ... opening in a new tab
      help.include?('rel="noopener noreferrer"') &&
      help.include?("```")                                    # command survives as a code block

  ensure
    ENV['HOME'] = real_home
  end
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
check('RSTUDIO_DATA_HOME is pinned per-slot (a user rc export otherwise breaks isolation)') do
  # Both places: rserver's env (inherits the job's) and the rsession wrapper
  # (rserver strips the session env, so the wrapper is the authoritative one).
  sh.include?('export RSTUDIO_DATA_HOME="${SLOT_DIR}/data/rstudio"') &&
    sh.include?('--env RSTUDIO_DATA_HOME="${SLOT_DIR}/data/rstudio"')
end
check('renv cache (XDG_CACHE_HOME) stays SHARED, not per-slot') do
  sh.include?('export XDG_CACHE_HOME="${SHARED_CACHE}"') && sh.include?('SHARED_CACHE="${RSTUDIO_WORK_DIR}/.cache"')
end
check('binds come from RSTUDIO_BIND_PATHS') { sh.include?("'#{DATA}'") && sh.include?("'/etc/slurm'") }
check('no site-specific /data1 left hard-coded in the singularity call') do
  sh.each_line.none? { |l| l.include?('-B') && l.include?('/data1') }
end
check('missing bind paths are skipped, not fatal') { sh.include?('bind path not present on this node, skipping') }
check('the job script stamps the slot as used at launch (fixes the "last used" hint)') do
  sh.include?('touch "${SLOT_DIR}"')
end
check('update notice falls back to the default app dir when config predates RSTUDIO_APP_DIR') do
  # Render with the key absent: the notice must still have a stamp path to read.
  conf_no_appdir = File.join(FIX, 'config-no-appdir')
  File.write(conf_no_appdir, File.read(CONFIG).lines.reject { |l| l.start_with?('RSTUDIO_APP_DIR') }.join)
  begin
    ENV['RSTUDIO_DEV_CONFIG'] = conf_no_appdir
    out = render(script_erb, context_for(
      rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
      session_name: 'default', new_session_name: ''
    ).instance_eval { context = self; binding })
    out.include?('/ondemand/dev/rstudio_dev"')
  ensure
    ENV['RSTUDIO_DEV_CONFIG'] = CONFIG
  end
end
check('the launch caches its verdict for the form (PUN must not make network calls)') do
  sh.include?('/.config/rstudio_dev/update-notice') &&
    sh.include?('rm -f "${_cache}"')        # cleared when current
end
check('update NOTICE: non-blocking version check, surfaced in the R banner, never auto-applied') do
  sh.include?("_app_dir=\"#{APPDIR}\"") &&                     # stamp path from config
    sh.include?('curl -fsS --max-time 3') &&                     # bounded, silent-fail
    sh.include?('export RSTUDIO_UPDATE_LATEST=') &&              # structured, for the banner
    sh.include?('Sys.getenv("RSTUDIO_UPDATE_LATEST"') &&         # site profile composes it
    sh.include?('What changed:') &&                              # banner links the changelog
    !sh.match?(/git pull|--app-only[^"]*\|\s*bash.*<%/)         # no self-update machinery
end
check('rserver logs to stderr (output.log), rsession to a file in the session dir') do
  # rsession forwards its own stderr into the R console after startup, so a
  # stderr logger for rsession sprays benign /proc-race ERRORs at the user.
  # rserver must KEEP stderr: startup failures otherwise vanish (no syslog).
  logconf = sh[/cat > "\$\{TMPDIR\}\/logging\.conf" <<LOGCONF\n(.*?)\nLOGCONF/m, 1].to_s
  logconf.include?("[*]\nlog-level=warn\nlogger-type=stderr") &&
    logconf.include?("[rsession]") &&
    logconf[/\[rsession\].*?logger-type=(\w+)/m, 1] == 'file' &&
    logconf.include?('log-dir=${SESSION_DIR}/logs') &&
    sh.include?('mkdir -p "${SESSION_DIR}/logs"') &&
    sh.include?('SESSION_DIR="${PWD}"')
end
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

# --- AI agent access (MCP) ---
# Three-way form select: off (default) | read | execute. The wrapper exports are
# the contract: the site-profile hook and the agent's MCP server both read them.

check('agent access defaults OFF: the wrapper exports nothing MCP-related') do
  # The site profile always CONTAINS the env-gated hook (it is a static file);
  # what must be absent in an Off session is the exports that would arm it.
  !sh.include?('export RSTUDIO_MCP_ACCESS') && !sh.include?('export BTW_RUN_R_ENABLED')
end

mcp_exec = render(script_erb, context_for(
  rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
  session_name: 'default', new_session_name: '', agent_access: 'execute'
).instance_eval { context = self; binding })
File.write(File.join(OUT, 'script-mcp.sh'), mcp_exec)   # run.sh bash-parses this too

check('execute mode: wrapper exports the mode, the execute tools (run_r + pkg), and btw\'s gate') do
  mcp_exec.include?('export RSTUDIO_MCP_ACCESS="execute"') &&
    mcp_exec.match?(/export RSTUDIO_MCP_TOOLS="[A-Za-z0-9_,]*,run_r,pkg"/) &&
    mcp_exec.include?('export BTW_RUN_R_ENABLED="true"')
end
check('the site profile registers the session via the rstudio.sessionInit hook (fires after renv)') do
  mcp_exec.include?('rstudio.sessionInit') && mcp_exec.include?('mcptools::mcp_session()')
end
check('execute mode disarms the hookable prompts that would deadlock the session') do
  mcp_exec.include?('needs.promptUser = FALSE') &&
    mcp_exec.include?('renv.consent     = TRUE') &&
    mcp_exec.include?('askYesNo = function(msg, ...)')
end
# The AST gate must be anchored to the STAGING dir. app_dir would point at the
# stable app for every staged app (they share one config), resolving to a
# missing file and silently serving an UNGUARDED run_r. The negative clause
# checks against the FIXTURE's app dir (APPDIR) -- a hard-coded
# "ondemand/dev/rstudio_dev" pattern could never fire here, because the
# hermetic fixture's app dir doesn't contain that path.
check('execute mode points the MCP guard at the staged copy, never at app_dir') do
  mcp_exec.include?('export RSTUDIO_MCP_GUARD="${SESSION_DIR}/mcp-guard.R"') &&
    !mcp_exec.match?(/RSTUDIO_MCP_GUARD="#{Regexp.escape(APPDIR)}/)
end

mcp_read = render(script_erb, context_for(
  rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
  session_name: 'default', new_session_name: '', agent_access: 'read'
).instance_eval { context = self; binding })
check('read mode: no run_r or pkg in the tool list, and btw\'s gate closed EXPLICITLY') do
  mcp_read.include?('export RSTUDIO_MCP_ACCESS="read"') &&
    !mcp_read.match?(/export RSTUDIO_MCP_TOOLS="[^"]*run_r/) &&
    !mcp_read.match?(/export RSTUDIO_MCP_TOOLS="[^"]*,pkg/) &&
    # an explicit false, not absence: btw serves an explicitly NAMED run_r
    # with the var unset (match_mode = "explicit"), so absence is not safety
    mcp_read.include?('export BTW_RUN_R_ENABLED="false"') &&
    !mcp_read.include?('export BTW_RUN_R_ENABLED="true"')
end
# Read mode has no run_r, so it gets no AST gate. The gate is ERB-gated and
# really is absent; the prompt-disarming is not -- the site profile is a STATIC
# heredoc gated at RUNTIME on RSTUDIO_MCP_ACCESS, so its text renders in every
# mode and simply never executes here. Assert each where it actually lives,
# or the test lies about which mechanism protects read mode.
check('read mode ships no AST gate (no run_r to guard)') do
  !mcp_read.include?('RSTUDIO_MCP_GUARD')
end
check('the prompt-disarming is runtime-gated on execute, so read mode never applies it') do
  mcp_read.include?('needs.promptUser') &&                      # static text: present
    mcp_read.include?('if (identical(mode, "execute")) {')      # but gated at runtime
end

mcp_evil = render(script_erb, context_for(
  rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
  session_name: 'default', new_session_name: '', agent_access: 'execute"; rm -rf /'
).instance_eval { context = self; binding })
check('an unrecognised agent_access value is allowlisted down to Off, never interpolated') do
  !mcp_evil.include?('export RSTUDIO_MCP_ACCESS') && !mcp_evil.include?('rm -rf')
end

# btw's BTW_RUN_R_ENABLED only gates its DEFAULT tool set -- a list that NAMES
# run_r is served regardless (match_mode = "explicit", btw 1.3.0). So read-only
# needs two mechanisms and both get asserted: the execute tools are FILTERED
# out of the list even when config injects them, and the env var is exported
# as an explicit "false", not left absent.
check('read mode strips run_r/pkg injected via config, and closes btw\'s gate explicitly') do
  conf_run_r = File.join(FIX, 'config-run-r')
  File.write(conf_run_r, File.read(CONFIG) + "RSTUDIO_MCP_TOOLS=env,docs,run_r,pkg\n")
  begin
    ENV['RSTUDIO_DEV_CONFIG'] = conf_run_r
    injected = render(script_erb, context_for(
      rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
      session_name: 'default', new_session_name: '', agent_access: 'read'
    ).instance_eval { context = self; binding })
  ensure
    ENV['RSTUDIO_DEV_CONFIG'] = CONFIG
  end
  injected.include?('export RSTUDIO_MCP_TOOLS="env,docs"') &&
    injected.include?('export BTW_RUN_R_ENABLED="false"')
end
check('a config tool list that scrubs to empty falls back to the read default, not btw\'s full set') do
  conf_junk = File.join(FIX, 'config-junk-tools')
  File.write(conf_junk, File.read(CONFIG) + "RSTUDIO_MCP_TOOLS=!!!\n")
  begin
    ENV['RSTUDIO_DEV_CONFIG'] = conf_junk
    junk = render(script_erb, context_for(
      rstudio_image: File.join(IMAGES, 'rstudio-4.6.sif'),
      session_name: 'default', new_session_name: '', agent_access: 'read'
    ).instance_eval { context = self; binding })
  ensure
    ENV['RSTUDIO_DEV_CONFIG'] = CONFIG
  end
  junk.include?('export RSTUDIO_MCP_TOOLS="env,docs,sessioninfo,ide"')
end
check('execute mode warns in output.log when the staged guard file is missing') do
  mcp_exec.include?('run_r will be UNGUARDED') && !mcp_read.include?('run_r will be UNGUARDED')
end

# ------------------------------------------------- the guard artifact itself --
# The suite cannot run R, but it CAN assert the artifact exists and is wired --
# which is exactly what "delete mcp-guard.R and strip the wiring" gets past
# text-only template assertions (tried: 61 passed with the feature gone).

guard_src = File.join(APP, 'template', 'mcp-guard.R')
check('mcp-guard.R ships in template/ and defines guard_btw_tools') do
  File.exist?(guard_src) &&
    File.read(guard_src).include?('guard_btw_tools <- function') &&
    File.read(guard_src).include?('S7::S7_data')
end
check('the guard knows the measured hazards, including the base-R modal') do
  g = File.read(guard_src)
  %w[readline browser file.choose showQuestion getPass locator].all? { |h| g.include?(h) }
end

wrappers_src = File.read(File.join(APP, 'r-wrappers.sh'))
check('r-wrappers has exactly ONE copy of the server command (write path and snippet cannot drift)') do
  wrappers_src.scan('mcptools::mcp_server').length == 1
end
check('the .mcp.json entry is valid JSON and wires the guard with its failure modes') do
  entry = wrappers_src[/^ENTRY\n(.*?)\nENTRY$/m, 1] ||
          wrappers_src[/cat <<'ENTRY'\n(.*?)\nENTRY/m, 1]
  next false unless entry
  doc = JSON.parse("{\n  \"mcpServers\": {\n#{entry}\n  }\n}")
  cmd = doc.dig('mcpServers', 'r-session', 'args', 2).to_s
  cmd.include?('RSTUDIO_MCP_GUARD') &&        # sources the gate
    cmd.include?('guard_btw_tools(') &&       # and applies it
    cmd.include?('broken deploy') &&          # stop()s on set-but-missing
    cmd.include?("if (!nzchar(tl)) tl <- 'env,docs,sessioninfo'")  # empty != unset
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
