# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'json'
require 'digest'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

# Top-level execution is guarded by __FILE__ == $PROGRAM_NAME, so requiring the
# step here defines the functions without running the upload.
require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  GROUP_COLORS = [
    "\e[34;1m",
    "\e[35;1m",
    "\e[36;1m",
    "\e[33;1m"
  ].freeze

  def initialize(output)
    super
    @depth   = 0
    @top_idx = -1
    @failures = []
    @counts  = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      @top_idx = (@top_idx + 1) % GROUP_COLORS.size
      output.puts "  #{GROUP_COLORS[@top_idx]}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each { |line| output.puts "     \e[31m#{line.rstrip}\e[0m" }
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Subprocess Sandbox ───────────────────────────────────────────────────────
#
# The subprocess tests run the real main.rb, which uploads over HTTP, shells out
# to `zip`, sleeps 10s before the log upload and deletes files. This file is
# preloaded with `ruby -r` ahead of main.rb so none of that leaves the test:
#
#   * Net::HTTP#request never opens a socket. It records the request and answers
#     with a scripted status (AC_SANDBOX_CHUNK_STATUSES / _COMPLETE_STATUSES,
#     comma separated, 200 once the list runs out). Any host other than
#     upload.example.test is refused.
#   * Dir.glob, File.delete, Dir.rmdir, FileUtils.cp and write-mode File.open are
#     refused outside AC_SANDBOX_ROOT (a per-test temp dir).
#   * The `zip` backtick and `sleep` are recorded instead of executed.
#   * Retriable's back-off sleep is disabled.
#   * Line coverage of main.rb is collected and written out for the report.
SANDBOX_SOURCE = <<~'RUBY'
  require 'coverage'
  Coverage.start

  require 'json'
  require 'net/http'
  require 'fileutils'
  require 'digest'
  require 'uri'
  begin
    require 'retriable'
    Retriable.configure { |c| c.sleep_disabled = true }
  rescue LoadError
    nil
  end

  module AcSandbox
    HOST  = 'upload.example.test'
    ROOT  = ENV.fetch('AC_SANDBOX_ROOT')
    ROOTS = [ROOT, File.realpath(ROOT)].uniq.freeze
    LOG   = File.join(ROOT, 'sandbox_events.jsonl')
    COV   = File.join(ROOT, 'sandbox_coverage.json')

    @counters = Hash.new(0)

    def self.record(event)
      File.open(LOG, 'a') { |f| f.puts(JSON.generate(event)) }
    end

    def self.inside?(path)
      full = File.expand_path(path.to_s)
      ROOTS.any? { |r| full == r || full.start_with?("#{r}/") }
    end

    def self.guard!(operation, path)
      return if inside?(path)

      raise SecurityError, "sandbox: blocked #{operation} outside the test root: #{path}"
    end

    def self.next_status(kind)
      index = @counters[kind]
      @counters[kind] += 1
      statuses = ENV.fetch("AC_SANDBOX_#{kind.upcase}_STATUSES", '').split(',')
      (statuses[index] || '200').to_i
    end
  end

  Dir.singleton_class.prepend(Module.new do
    def glob(pattern, *args, **kwargs, &block)
      AcSandbox.guard!('Dir.glob', pattern)
      super
    end

    def rmdir(path)
      AcSandbox.guard!('Dir.rmdir', path)
      super
    end
  end)

  File.singleton_class.prepend(Module.new do
    def delete(*paths)
      paths.each { |p| AcSandbox.guard!('File.delete', p) }
      super
    end

    def open(path, mode = 'r', *args, **kwargs, &block)
      AcSandbox.guard!('File.open(write)', path) if mode.to_s.match?(/[wa+]/)
      super
    end
  end)

  FileUtils.singleton_class.prepend(Module.new do
    def cp(src, dest, **options)
      AcSandbox.guard!('FileUtils.cp', dest)
      super
    end
  end)

  def `(command)
    AcSandbox.record('type' => 'shell', 'command' => command)
    target = command[/zip -r "([^"]+)"/, 1]
    if target
      AcSandbox.guard!('zip', target)
      File.write(target, "zip-stub:#{command}")
    end
    ''
  end

  def sleep(seconds = nil)
    AcSandbox.record('type' => 'sleep', 'seconds' => seconds)
    0
  end

  Net::HTTP.prepend(Module.new do
    def request(req, body = nil, &block)
      unless address == AcSandbox::HOST
        raise SecurityError, "sandbox: network blocked for host #{address.inspect}"
      end

      kind = req.path.include?('chunk') ? 'chunk' : 'complete'
      event = {
        'type' => 'http', 'kind' => kind, 'method' => req.method, 'path' => req.path,
        'use_ssl' => use_ssl?, 'read_timeout' => read_timeout,
        'content_type' => req['Content-Type']
      }
      form = req.instance_variable_get(:@body_data)
      if form
        event['fields'] = form.each_with_object({}) do |(key, value), fields|
          if value.respond_to?(:read)
            bytes = value.read
            fields[key] = { 'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes).upcase }
          else
            fields[key] = value
          end
        end
      end
      event['body'] = req.body if req.body
      status = AcSandbox.next_status(kind)
      event['status'] = status
      AcSandbox.record(event)

      klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPUnknownResponse
      response = klass.new('1.1', status.to_s, 'sandbox')
      response.instance_variable_set(:@body, status < 400 ? '{}' : 'sandbox error')
      response.instance_variable_set(:@read, true)
      response
    end
  end)

  at_exit do
    result = Coverage.result.select { |path, _| path.end_with?('/main.rb') }
    File.write(AcSandbox::COV, JSON.generate(result))
  end
RUBY

# Line coverage reported by the subprocess runs, merged into the final report.
$subprocess_coverage = nil

def merge_subprocess_coverage(path)
  return unless File.exist?(path)

  JSON.parse(File.read(path)).each_value do |lines|
    $subprocess_coverage ||= Array.new(lines.size)
    lines.each_with_index do |count, i|
      next if count.nil?

      $subprocess_coverage[i] = $subprocess_coverage[i].to_i + count
    end
  end
end

# Outcome of one main.rb run, with the sandbox events parsed.
class MainRun
  attr_reader :out, :err, :status, :events, :root

  def initialize(out, err, status, events, root)
    @out, @err, @status, @events, @root = out, err, status, events, root
  end

  def exitstatus     = status.exitstatus
  def success?       = status.success?
  def requests       = events.select { |e| e['type'] == 'http' }
  def chunks         = requests.select { |e| e['kind'] == 'chunk' }
  def completes      = requests.select { |e| e['kind'] == 'complete' }
  def shell_commands = events.select { |e| e['type'] == 'shell' }.map { |e| e['command'] }
  def sleeps         = events.select { |e| e['type'] == 'sleep' }.map { |e| e['seconds'] }
  def complete_body  = completes.last && JSON.parse(completes.last['body'])
  def chunk_fields   = chunks.map { |c| c['fields'] }
end

CHUNK_URL    = 'https://upload.example.test/build/uploadchunk'
COMPLETE_URL = 'https://upload.example.test/build/completeupload'
AGENT_ID     = '11111111-2222-3333-4444-555555555555'
QUEUE_ID     = '66666666-7777-8888-9999-000000000000'
ZERO_GUID    = '00000000-0000-0000-0000-000000000000'

# Every variable main.rb reads, unset by default so the ambient environment can
# never mask a missing-variable test.
STEP_ENV_KEYS = %w[
  AC_UPLOAD_DIR AC_UPLOADCHUNK_URL AC_COMPLETEUPLOAD_URL AC_AGENT_ID AC_QUEUE_ID
  AC_IS_SUCCESS AC_DISABLE_UPLOAD_ON_FAIL AC_LOGFILE AC_TOKEN_ID
].freeze

# A valid configuration that uploads <root>/upload.
def base_env(root)
  {
    'AC_UPLOAD_DIR'         => File.join(root, 'upload'),
    'AC_UPLOADCHUNK_URL'    => CHUNK_URL,
    'AC_COMPLETEUPLOAD_URL' => COMPLETE_URL,
    'AC_AGENT_ID'           => AGENT_ID,
    'AC_QUEUE_ID'           => QUEUE_ID
  }
end

# Run main.rb in a child process, inside the sandbox, with `root` as the working
# directory (the step writes its ac_chunk_N temp files to the cwd).
def run_main(root, env = {}, chunk_statuses: nil, complete_statuses: nil)
  sandbox = File.join(root, 'sandbox.rb')
  File.write(sandbox, SANDBOX_SOURCE)

  child_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }
  child_env['AC_SANDBOX_ROOT']              = root
  child_env['AC_SANDBOX_CHUNK_STATUSES']    = chunk_statuses
  child_env['AC_SANDBOX_COMPLETE_STATUSES'] = complete_statuses
  child_env['RUBYOPT']                      = nil
  child_env.merge!(env)

  out, err, status = Open3.capture3(child_env, RbConfig.ruby, '-r', sandbox, MAIN_RB, chdir: root)

  log    = File.join(root, 'sandbox_events.jsonl')
  events = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  merge_subprocess_coverage(File.join(root, 'sandbox_coverage.json'))
  MainRun.new(out, err, status, events, root)
end

def write_file(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, content)
  path
end

def sha256(content) = Digest::SHA256.hexdigest(content).upcase

# Runs the example with ENV keys restored afterwards.
def with_env(vars)
  saved = vars.keys.to_h { |k| [k, ENV[k]] }
  vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

# ─── Tests ────────────────────────────────────────────────────────────────────

# ─── 0. Loading main.rb as a library ──────────────────────────────────────────
RSpec.describe 'loading main.rb as a library' do
  it 'does not run the step when required (no banner, no upload, no failure)' do
    out, err, status = Open3.capture3(
      STEP_ENV_KEYS.to_h { |k| [k, nil] },
      RbConfig.ruby, '-e', "require '#{MAIN_RB}'; puts 'loaded'"
    )
    expect(status.exitstatus).to eq(0)
    expect(out.strip).to eq('loaded')
    expect(err).to be_empty
  end

  it 'defines every function under test' do
    out, _err, status = Open3.capture3(
      RbConfig.ruby, '-e',
      "require '#{MAIN_RB}'; " \
      'puts %i[compute_file_sha256 format_bytes format_duration format_speed utc_timestamp ' \
      'delete_files_and_directories should_delete_artifacts?].all? { |m| respond_to?(m, true) }'
    )
    expect(status.exitstatus).to eq(0)
    expect(out.strip).to eq('true')
  end

  it 'does not register the failure banner hook when required' do
    out, _err, status = Open3.capture3(
      RbConfig.ruby, '-e', "require '#{MAIN_RB}'; raise 'boom from caller'"
    )
    expect(status.exitstatus).not_to eq(0)
    expect(out).not_to include('EXPORT BUILD ARTIFACTS FAILED')
  end
end

# ─── 1. compute_file_sha256 ───────────────────────────────────────────────────
RSpec.describe '#compute_file_sha256' do
  let(:tmpdir) { Dir.mktmpdir('sha256_test') }
  after { FileUtils.rm_rf(tmpdir) }

  context 'positive' do
    it 'returns the uppercase SHA256 of a small file' do
      path = write_file(File.join(tmpdir, 'abc.txt'), 'abc')
      expect(compute_file_sha256(path))
        .to eq('BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD')
    end

    it 'returns the SHA256 of empty input for a 0-byte file' do
      path = write_file(File.join(tmpdir, 'empty.bin'), '')
      expect(compute_file_sha256(path))
        .to eq('E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855')
    end

    [4095, 4096, 4097, 3 * 4096 + 17].each do |size|
      it "matches Digest::SHA256.file for a #{size}-byte file (4KB read boundary)" do
        content = Random.new(size).bytes(size)
        path = write_file(File.join(tmpdir, "f#{size}.bin"), content)
        expect(compute_file_sha256(path)).to eq(Digest::SHA256.file(path).hexdigest.upcase)
      end
    end

    it 'hashes binary content byte-for-byte (NUL and high bytes)' do
      content = "\x00\xFF\x00\x80binary\r\n".b
      path = write_file(File.join(tmpdir, 'bin.dat'), content)
      expect(compute_file_sha256(path)).to eq(sha256(content))
    end

    it 'returns only uppercase hex characters' do
      path = write_file(File.join(tmpdir, 'x.txt'), 'appcircle')
      expect(compute_file_sha256(path)).to match(/\A[0-9A-F]{64}\z/)
    end

    it 'gives different hashes for different content' do
      a = write_file(File.join(tmpdir, 'a.txt'), 'a')
      b = write_file(File.join(tmpdir, 'b.txt'), 'b')
      expect(compute_file_sha256(a)).not_to eq(compute_file_sha256(b))
    end
  end

  context 'negative' do
    it 'raises Errno::ENOENT for a missing file' do
      expect { compute_file_sha256(File.join(tmpdir, 'missing.txt')) }.to raise_error(Errno::ENOENT)
    end

    it 'raises TypeError for a nil path' do
      expect { compute_file_sha256(nil) }.to raise_error(TypeError)
    end

    it 'raises Errno::ENOENT for an empty path' do
      expect { compute_file_sha256('') }.to raise_error(Errno::ENOENT)
    end

    it 'raises Errno::EISDIR for a directory' do
      expect { compute_file_sha256(tmpdir) }.to raise_error(Errno::EISDIR)
    end
  end
end

# ─── 2. format_bytes ──────────────────────────────────────────────────────────
RSpec.describe '#format_bytes' do
  context 'positive' do
    {
      0                 => '0 B',
      1                 => '1 B',
      999               => '999 B',
      1000              => '1.0 KB',
      1500              => '1.5 KB',
      1_000_000         => '1.0 MB',
      1_234_567         => '1.23 MB',
      100_000_000       => '100.0 MB',
      1_000_000_000     => '1.0 GB',
      1_000_000_000_000 => '1.0 TB'
    }.each do |bytes, expected|
      it "formats #{bytes} as '#{expected}' (decimal units)" do
        expect(format_bytes(bytes)).to eq(expected)
      end
    end

    it 'keeps TB as the largest unit' do
      expect(format_bytes(5_000_000_000_000_000)).to eq('5000.0 TB')
    end

    it 'keeps the raw value for byte counts below 1000, including floats' do
      expect(format_bytes(999.5)).to eq('999.5 B')
    end

    it 'rounds after scaling, so 999_999 shows as 1000.0 KB rather than 1.0 MB' do
      expect(format_bytes(999_999)).to eq('1000.0 KB')
    end

    it 'accepts numeric strings through to_f' do
      expect(format_bytes('2500')).to eq('2.5 KB')
    end
  end

  context 'negative' do
    it 'does not scale negative values' do
      expect(format_bytes(-5000)).to eq('-5000 B')
    end

    it "renders nil as ' B' (nil.to_f is 0)" do
      expect(format_bytes(nil)).to eq(' B')
    end

    it 'renders a non-numeric string verbatim with a B unit' do
      expect(format_bytes('abc')).to eq('abc B')
    end

    it 'raises NoMethodError for an object without to_f' do
      expect { format_bytes(Object.new) }.to raise_error(NoMethodError)
    end
  end
end

# ─── 3. format_duration ───────────────────────────────────────────────────────
RSpec.describe '#format_duration' do
  context 'positive' do
    {
      0      => '0ms',
      0.0004 => '0ms',
      0.41   => '410ms',
      1      => '1s',
      1.0    => '1.0s',
      1.234  => '1.23s',
      59.994 => '59.99s',
      60     => '1m 0s',
      92.3   => '1m 32s',
      3725   => '62m 5s'
    }.each do |seconds, expected|
      it "formats #{seconds}s as '#{expected}'" do
        expect(format_duration(seconds)).to eq(expected)
      end
    end
  end

  context 'boundaries' do
    it 'rounds 0.9996s up to 1000ms instead of switching to seconds' do
      expect(format_duration(0.9996)).to eq('1000ms')
    end

    it 'rounds 59.996s up to 60.0s instead of switching to minutes' do
      expect(format_duration(59.996)).to eq('60.0s')
    end

    it 'rounds 119.6s to 1m 60s (seconds are not carried into minutes)' do
      expect(format_duration(119.6)).to eq('1m 60s')
    end
  end

  context 'negative' do
    it 'formats negative values as milliseconds' do
      expect(format_duration(-0.5)).to eq('-500ms')
      expect(format_duration(-120)).to eq('-120000ms')
    end

    it 'raises NoMethodError for nil' do
      expect { format_duration(nil) }.to raise_error(NoMethodError)
    end

    it 'raises ArgumentError for a string' do
      expect { format_duration('5') }.to raise_error(ArgumentError, /comparison of String/)
    end
  end
end

# ─── 4. format_speed ──────────────────────────────────────────────────────────
RSpec.describe '#format_speed' do
  context 'positive' do
    it 'returns MB/s using decimal megabytes' do
      expect(format_speed(1_000_000, 1.0)).to eq('1.0 MB/s')
    end

    it 'divides by the elapsed time' do
      expect(format_speed(5_000_000, 2.0)).to eq('2.5 MB/s')
    end

    it 'rounds to two decimals' do
      expect(format_speed(123_456_789, 1.5)).to eq('82.3 MB/s')
    end

    it 'returns 0.0 MB/s for zero bytes' do
      expect(format_speed(0, 1.0)).to eq('0.0 MB/s')
    end
  end

  context 'negative' do
    it "returns '-' for zero seconds (no division by zero)" do
      expect(format_speed(100, 0)).to eq('-')
      expect(format_speed(100, 0.0)).to eq('-')
    end

    it "returns '-' for negative seconds" do
      expect(format_speed(100, -1)).to eq('-')
    end

    it 'raises NoMethodError for nil seconds' do
      expect { format_speed(100, nil) }.to raise_error(NoMethodError)
    end

    it 'raises NoMethodError for nil bytes' do
      expect { format_speed(nil, 1.0) }.to raise_error(NoMethodError)
    end
  end
end

# ─── 5. utc_timestamp ─────────────────────────────────────────────────────────
RSpec.describe '#utc_timestamp' do
  context 'positive' do
    it 'returns MM/DD/YYYY HH:MM:SS' do
      expect(utc_timestamp).to match(%r{\A\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}\z})
    end

    it 'converts the local time to UTC' do
      allow(Time).to receive(:now).and_return(Time.new(2026, 1, 2, 3, 4, 5, '+03:00'))
      expect(utc_timestamp).to eq('01/02/2026 00:04:05')
    end

    it 'crosses the date line backwards when the offset requires it' do
      allow(Time).to receive(:now).and_return(Time.new(2026, 3, 1, 1, 0, 0, '+03:00'))
      expect(utc_timestamp).to eq('02/28/2026 22:00:00')
    end

    it 'uses a 24-hour clock' do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 12, 31, 23, 59, 59))
      expect(utc_timestamp).to eq('12/31/2026 23:59:59')
    end
  end

  context 'negative' do
    it 'propagates a failure from the clock' do
      allow(Time).to receive(:now).and_return(nil)
      expect { utc_timestamp }.to raise_error(NoMethodError)
    end
  end
end

# ─── 6. delete_files_and_directories ──────────────────────────────────────────
RSpec.describe '#delete_files_and_directories' do
  let(:tmpdir) { Dir.mktmpdir('delete_test') }
  let(:target) { File.join(tmpdir, 'upload') }
  before { FileUtils.mkdir_p(target) }
  after  { FileUtils.rm_rf(tmpdir) }

  context 'positive' do
    it 'deletes files and nested directories but keeps the folder itself' do
      write_file(File.join(target, 'a.txt'), 'a')
      write_file(File.join(target, 'sub', 'b.txt'), 'b')
      write_file(File.join(target, 'sub', 'deeper', 'c.txt'), 'c')

      delete_files_and_directories(target)

      expect(Dir.exist?(target)).to be(true)
      expect(Dir.children(target)).to be_empty
    end

    it 'removes empty subdirectories' do
      FileUtils.mkdir_p(File.join(target, 'empty', 'nested'))
      delete_files_and_directories(target)
      expect(Dir.children(target)).to be_empty
    end

    it 'is a no-op on an empty folder' do
      expect { delete_files_and_directories(target) }.not_to raise_error
      expect(Dir.exist?(target)).to be(true)
    end

    it 'does not touch anything outside the folder' do
      sibling = write_file(File.join(tmpdir, 'keep.txt'), 'keep')
      write_file(File.join(target, 'a.txt'), 'a')
      delete_files_and_directories(target)
      expect(File.exist?(sibling)).to be(true)
    end
  end

  context 'negative' do
    it 'is a no-op for a folder that does not exist' do
      expect { delete_files_and_directories(File.join(tmpdir, 'missing')) }.not_to raise_error
    end

    it 'leaves a regular file path untouched (only folder contents are globbed)' do
      file = write_file(File.join(tmpdir, 'artifact.ipa'), 'ipa')
      delete_files_and_directories(file)
      expect(File.exist?(file)).to be(true)
    end

    it 'skips dotfiles, so a subfolder holding one is not removed' do
      write_file(File.join(target, '.hidden'), 'h')
      write_file(File.join(target, 'sub', '.hidden'), 'h')
      write_file(File.join(target, 'sub', 'visible.txt'), 'v')

      delete_files_and_directories(target)

      expect(File.exist?(File.join(target, '.hidden'))).to be(true)
      expect(File.exist?(File.join(target, 'sub', '.hidden'))).to be(true)
      expect(File.exist?(File.join(target, 'sub', 'visible.txt'))).to be(false)
    end

    it "follows a directory symlink, empties its target, then fails to rmdir the link" do
      outside = File.join(tmpdir, 'outside')
      write_file(File.join(outside, 'precious.txt'), 'p')
      File.symlink(outside, File.join(target, 'link'))

      expect { delete_files_and_directories(target) }.to raise_error(Errno::ENOTDIR)
      expect(File.exist?(File.join(outside, 'precious.txt'))).to be(false)
    end

    it "expands a nil folder to the '/*' glob (filesystem root); glob stubbed" do
      expect(Dir).to receive(:glob).with('/*').and_return([])
      delete_files_and_directories(nil)
    end

    it "expands an empty folder to the '/*' glob (filesystem root); glob stubbed" do
      expect(Dir).to receive(:glob).with('/*').and_return([])
      delete_files_and_directories('')
    end

    it 'propagates a delete failure' do
      write_file(File.join(target, 'locked.txt'), 'x')
      allow(File).to receive(:delete).and_raise(Errno::EACCES)
      expect { delete_files_and_directories(target) }.to raise_error(Errno::EACCES)
    end
  end
end

# ─── 7. should_delete_artifacts? ──────────────────────────────────────────────
RSpec.describe '#should_delete_artifacts?' do
  def decide(disable, success)
    with_env('AC_DISABLE_UPLOAD_ON_FAIL' => disable, 'AC_IS_SUCCESS' => success) do
      should_delete_artifacts?
    end
  end

  context 'positive (artifacts are deleted)' do
    it "when AC_DISABLE_UPLOAD_ON_FAIL='true' and AC_IS_SUCCESS='false'" do
      expect(decide('true', 'false')).to be(true)
    end

    it "when AC_DISABLE_UPLOAD_ON_FAIL='true' and AC_IS_SUCCESS is missing" do
      expect(decide('true', nil)).to be(true)
    end

    it "when AC_DISABLE_UPLOAD_ON_FAIL='true' and AC_IS_SUCCESS is empty" do
      expect(decide('true', '')).to be(true)
    end

    it "when AC_DISABLE_UPLOAD_ON_FAIL='true' and AC_IS_SUCCESS='TRUE' (only true/True count as success)" do
      expect(decide('true', 'TRUE')).to be(true)
    end
  end

  context 'negative (artifacts are kept)' do
    it "when the build succeeded with AC_IS_SUCCESS='true'" do
      expect(decide('true', 'true')).to be(false)
    end

    it "when the build succeeded with AC_IS_SUCCESS='True'" do
      expect(decide('true', 'True')).to be(false)
    end

    it "when AC_DISABLE_UPLOAD_ON_FAIL='false'" do
      expect(decide('false', 'false')).to be(false)
    end

    it 'when AC_DISABLE_UPLOAD_ON_FAIL is missing' do
      expect(decide(nil, 'false')).to be(false)
    end

    it 'when AC_DISABLE_UPLOAD_ON_FAIL is empty' do
      expect(decide('', 'false')).to be(false)
    end

    it "when AC_DISABLE_UPLOAD_ON_FAIL='True' (only the exact 'true' enables it)" do
      expect(decide('True', 'false')).to be(false)
    end
  end
end

# ─── 8. ENV validation (subprocess – main.rb) ─────────────────────────────────
RSpec.describe 'ENV validation (subprocess – main.rb)' do
  let(:root)   { Dir.mktmpdir('export_artifacts_env') }
  let(:upload) { File.join(root, 'upload') }
  let(:env)    { base_env(root) }
  before { write_file(File.join(upload, 'app.apk'), 'apk-bytes') }
  after  { FileUtils.rm_rf(root) }

  context 'AC_UPLOAD_DIR' do
    it 'missing: fails with a TypeError before uploading anything' do
      run = run_main(root, env.merge('AC_UPLOAD_DIR' => nil))
      expect(run.exitstatus).not_to eq(0)
      expect(run.err).to include('no implicit conversion of nil into String')
      expect(run.out).to include('EXPORT BUILD ARTIFACTS FAILED')
      expect(run.requests).to be_empty
    end

    it "empty: is not validated and resolves to the filesystem root '/*' (blocked by the sandbox)" do
      run = run_main(root, env.merge('AC_UPLOAD_DIR' => ''))
      expect(run.exitstatus).not_to eq(0)
      expect(run.err).to include('sandbox: blocked Dir.glob outside the test root: /*')
      expect(run.requests).to be_empty
    end

    it "empty with AC_DISABLE_UPLOAD_ON_FAIL on a failed build: tries to wipe '/*' (blocked by the sandbox)" do
      run = run_main(root, env.merge('AC_UPLOAD_DIR' => '', 'AC_DISABLE_UPLOAD_ON_FAIL' => 'true',
                                     'AC_IS_SUCCESS' => 'false'))
      expect(run.exitstatus).not_to eq(0)
      expect(run.err).to include('sandbox: blocked Dir.glob outside the test root: /*')
      expect(run.err).to include('delete_files_and_directories')
    end

    it 'set to a directory that does not exist: completes with no files' do
      run = run_main(root, env.merge('AC_UPLOAD_DIR' => File.join(root, 'nope')))
      expect(run.exitstatus).to eq(0)
      expect(run.chunks).to be_empty
      expect(run.complete_body['files']).to eq([])
    end
  end

  context 'AC_UPLOADCHUNK_URL' do
    it 'missing: fails with an ArgumentError from URI()' do
      run = run_main(root, env.merge('AC_UPLOADCHUNK_URL' => nil))
      expect(run.exitstatus).not_to eq(0)
      expect(run.err).to include('bad argument (expected URI object or URI string)')
      expect(run.out).to include('EXPORT BUILD ARTIFACTS FAILED')
      expect(run.requests).to be_empty
    end

    it "empty: every chunk attempt fails with 'not an HTTP URI' and the step fails" do
      run = run_main(root, env.merge('AC_UPLOADCHUNK_URL' => ''))
      expect(run.exitstatus).not_to eq(0)
      expect(run.out).to include('attempt 3/3  FAILED')
      expect(run.out).to include('not an HTTP URI')
      expect(run.out).to include('file   : app.apk')
      expect(run.requests).to be_empty
    end

    it 'empty with nothing to upload: is never used and the step succeeds' do
      FileUtils.rm_rf(Dir.glob(File.join(upload, '*')))
      run = run_main(root, env.merge('AC_UPLOADCHUNK_URL' => ''))
      expect(run.exitstatus).to eq(0)
      expect(run.completes.size).to eq(1)
    end
  end

  context 'AC_COMPLETEUPLOAD_URL' do
    it 'missing: fails with an ArgumentError from URI() before any chunk is sent' do
      run = run_main(root, env.merge('AC_COMPLETEUPLOAD_URL' => nil))
      expect(run.exitstatus).not_to eq(0)
      expect(run.err).to include('bad argument (expected URI object or URI string)')
      expect(run.requests).to be_empty
    end

    it "empty: chunks are uploaded, then the step fails with 'not an HTTP URI'" do
      run = run_main(root, env.merge('AC_COMPLETEUPLOAD_URL' => ''))
      expect(run.exitstatus).not_to eq(0)
      expect(run.err).to include('not an HTTP URI')
      expect(run.chunks.size).to eq(1)
      expect(run.completes).to be_empty
    end
  end

  context 'AC_AGENT_ID' do
    it 'missing: falls back to the zero GUID in chunk and complete requests' do
      run = run_main(root, env.merge('AC_AGENT_ID' => nil))
      expect(run.exitstatus).to eq(0)
      expect(run.chunk_fields.first['agentId']).to eq(ZERO_GUID)
      expect(run.complete_body['agentId']).to eq(ZERO_GUID)
    end

    it 'empty: is sent as an empty string (only a missing value falls back)' do
      run = run_main(root, env.merge('AC_AGENT_ID' => ''))
      expect(run.exitstatus).to eq(0)
      expect(run.chunk_fields.first['agentId']).to eq('')
      expect(run.complete_body['agentId']).to eq('')
    end

    it 'set: is forwarded as-is' do
      run = run_main(root, env)
      expect(run.chunk_fields.first['agentId']).to eq(AGENT_ID)
      expect(run.complete_body['agentId']).to eq(AGENT_ID)
    end
  end

  context 'AC_QUEUE_ID' do
    it 'missing: falls back to the zero GUID in chunk and complete requests' do
      run = run_main(root, env.merge('AC_QUEUE_ID' => nil))
      expect(run.exitstatus).to eq(0)
      expect(run.chunk_fields.first['queueId']).to eq(ZERO_GUID)
      expect(run.complete_body['queueId']).to eq(ZERO_GUID)
    end

    it 'empty: is sent as an empty string (only a missing value falls back)' do
      run = run_main(root, env.merge('AC_QUEUE_ID' => ''))
      expect(run.exitstatus).to eq(0)
      expect(run.chunk_fields.first['queueId']).to eq('')
      expect(run.complete_body['queueId']).to eq('')
    end

    it 'set: is forwarded as-is' do
      run = run_main(root, env)
      expect(run.chunk_fields.first['queueId']).to eq(QUEUE_ID)
      expect(run.complete_body['queueId']).to eq(QUEUE_ID)
    end
  end

  context 'AC_IS_SUCCESS' do
    it "missing: is reported as 'true'" do
      run = run_main(root, env.merge('AC_IS_SUCCESS' => nil))
      expect(run.exitstatus).to eq(0)
      expect(run.complete_body['isSuccess']).to eq('true')
    end

    it 'empty: is reported as an empty string' do
      run = run_main(root, env.merge('AC_IS_SUCCESS' => ''))
      expect(run.exitstatus).to eq(0)
      expect(run.complete_body['isSuccess']).to eq('')
    end

    it "set to 'false': is reported as 'false' and artifacts are still uploaded" do
      run = run_main(root, env.merge('AC_IS_SUCCESS' => 'false'))
      expect(run.exitstatus).to eq(0)
      expect(run.complete_body['isSuccess']).to eq('false')
      expect(run.chunks.size).to eq(1)
    end
  end

  context 'AC_DISABLE_UPLOAD_ON_FAIL' do
    it 'missing: artifacts of a failed build are uploaded' do
      run = run_main(root, env.merge('AC_IS_SUCCESS' => 'false'))
      expect(run.exitstatus).to eq(0)
      expect(run.chunks.size).to eq(1)
      expect(File.exist?(File.join(upload, 'app.apk'))).to be(true)
    end

    it 'empty: artifacts of a failed build are uploaded' do
      run = run_main(root, env.merge('AC_DISABLE_UPLOAD_ON_FAIL' => '', 'AC_IS_SUCCESS' => 'false'))
      expect(run.exitstatus).to eq(0)
      expect(run.chunks.size).to eq(1)
    end

    it "'true' on a failed build: the upload folder is emptied and no artifact is sent" do
      write_file(File.join(upload, 'reports', 'junit.xml'), '<xml/>')
      run = run_main(root, env.merge('AC_DISABLE_UPLOAD_ON_FAIL' => 'true', 'AC_IS_SUCCESS' => 'false'))
      expect(run.exitstatus).to eq(0)
      expect(Dir.children(upload)).to be_empty
      expect(run.chunks).to be_empty
      expect(run.shell_commands).to be_empty
      expect(run.complete_body['files']).to eq([])
      expect(run.complete_body['isSuccess']).to eq('false')
    end

    it "'true' on a successful build: artifacts are uploaded" do
      run = run_main(root, env.merge('AC_DISABLE_UPLOAD_ON_FAIL' => 'true', 'AC_IS_SUCCESS' => 'true'))
      expect(run.exitstatus).to eq(0)
      expect(run.chunks.size).to eq(1)
    end

    it "'true' with AC_IS_SUCCESS missing: artifacts are deleted although isSuccess is reported as 'true'" do
      run = run_main(root, env.merge('AC_DISABLE_UPLOAD_ON_FAIL' => 'true'))
      expect(run.exitstatus).to eq(0)
      expect(run.chunks).to be_empty
      expect(run.complete_body['isSuccess']).to eq('true')
    end

    it "'true' on a failed build with AC_UPLOAD_DIR pointing at a file: fails with NameError on 'entry'" do
      file = File.join(upload, 'app.apk')
      run = run_main(root, env.merge('AC_UPLOAD_DIR' => file, 'AC_DISABLE_UPLOAD_ON_FAIL' => 'true',
                                     'AC_IS_SUCCESS' => 'false'))
      expect(run.exitstatus).not_to eq(0)
      expect(run.err).to match(/NameError/)
      expect(run.err).to match(/entry/)
      expect(File.exist?(file)).to be(true)
      expect(run.requests).to be_empty
    end
  end

  context 'AC_LOGFILE' do
    let(:log) { File.join(root, 'build.log') }

    it 'missing: no log entry is uploaded' do
      run = run_main(root, env.merge('AC_LOGFILE' => nil))
      expect(run.exitstatus).to eq(0)
      expect(run.complete_body['files'].map { |f| f['key'] }).to eq(['artifact1'])
      expect(run.sleeps).to be_empty
    end

    it "empty: the '.snapshot' entry does not exist and is skipped" do
      run = run_main(root, env.merge('AC_LOGFILE' => ''))
      expect(run.exitstatus).to eq(0)
      expect(run.out).to include('SKIPPED : file does not exist (.snapshot)')
      expect(run.complete_body['files'].map { |f| f['key'] }).to eq(['artifact1'])
    end

    it 'set, without an existing .snapshot: the log is skipped as missing' do
      write_file(log, "line 1\n")
      run = run_main(root, env.merge('AC_LOGFILE' => log))
      expect(run.exitstatus).to eq(0)
      expect(run.out).to include("SKIPPED : file does not exist (#{log}.snapshot)")
      expect(run.complete_body['files'].map { |f| f['key'] }).to eq(['artifact1'])
      expect(run.sleeps).to be_empty
    end

    context 'set, with an existing .snapshot' do
      before do
        write_file(log, "fresh log line\n")
        write_file("#{log}.snapshot", "stale snapshot\n")
      end

      it "uploads the refreshed snapshot as 'log' / 'log.txt' after a 10s flush wait" do
        run = run_main(root, env.merge('AC_LOGFILE' => log))
        expect(run.exitstatus).to eq(0)
        expect(run.sleeps).to eq([10])
        log_chunk = run.chunk_fields.find { |f| f['name'] == 'log' }
        expect(log_chunk['filename']).to eq('build.log.snapshot')
        expect(run.complete_body['files']).to include('key' => 'log', 'value' => 'log.txt')
        snapshot = File.read("#{log}.snapshot")
        expect(snapshot).to start_with("fresh log line\n")
        expect(snapshot).to match(/\r\n@@\[section:end\] Step completed \d{2}\/\d{2}\/\d{4} \d{2}:\d{2}:\d{2}\z/)
        expect(log_chunk['chunk']['sha256']).to eq(sha256(snapshot))
      end

      it 'reports the hash of the stale snapshot, not of the uploaded content' do
        run = run_main(root, env.merge('AC_LOGFILE' => log))
        log_chunk = run.chunk_fields.find { |f| f['name'] == 'log' }
        expect(run.complete_body['fileHashes']['log.txt']).to eq(sha256("stale snapshot\n"))
        expect(run.complete_body['fileHashes']['log.txt']).not_to eq(log_chunk['chunk']['sha256'])
      end
    end
  end
end

# ─── 9. Upload flow (subprocess – main.rb) ────────────────────────────────────
RSpec.describe 'upload flow (subprocess – main.rb)' do
  let(:root)   { Dir.mktmpdir('export_artifacts_flow') }
  let(:upload) { File.join(root, 'upload') }
  let(:env)    { base_env(root) }
  after { FileUtils.rm_rf(root) }

  context 'positive' do
    before do
      write_file(File.join(upload, 'app.ipa'), 'ipa-content')
      write_file(File.join(upload, 'mapping.txt'), 'mapping-content')
    end

    it 'uploads every file as a single chunk and completes the upload' do
      run = run_main(root, env)
      expect(run.exitstatus).to eq(0)
      expect(run.chunks.size).to eq(2)
      expect(run.completes.size).to eq(1)
      expect(run.out).to include('EXPORT BUILD ARTIFACTS COMPLETED')
      expect(run.out).not_to include('FAILED')
    end

    it 'names artifacts artifact1..N in glob order and sends the multipart fields' do
      run = run_main(root, env)
      first, second = run.chunk_fields
      expect(first).to include('agentId' => AGENT_ID, 'queueId' => QUEUE_ID, 'name' => 'artifact1',
                               'filename' => 'app.ipa', 'offset' => '0', 'fileSize' => '11',
                               'chunkHash' => sha256('ipa-content'))
      expect(first['chunk']).to eq('size' => 11, 'sha256' => sha256('ipa-content'))
      expect(second).to include('name' => 'artifact2', 'filename' => 'mapping.txt')
      expect(first).not_to have_key('agentSecret')
    end

    it 'posts chunks as multipart to the chunk URL over SSL with a 600s timeout' do
      run = run_main(root, env)
      chunk = run.chunks.first
      expect(chunk).to include('method' => 'POST', 'path' => '/build/uploadchunk', 'use_ssl' => true,
                               'read_timeout' => 600)
    end

    it 'does not enable SSL for an http:// chunk URL' do
      run = run_main(root, env.merge('AC_UPLOADCHUNK_URL' => 'http://upload.example.test/build/uploadchunk'))
      expect(run.chunks.first['use_ssl']).to be(false)
    end

    it 'completes with JSON listing files and their SHA256 hashes' do
      run = run_main(root, env)
      complete = run.completes.first
      expect(complete).to include('path' => '/build/completeupload', 'content_type' => 'application/json')
      expect(run.complete_body).to eq(
        'agentId'    => AGENT_ID,
        'queueId'    => QUEUE_ID,
        'isSuccess'  => 'true',
        'files'      => [{ 'key' => 'artifact1', 'value' => 'app.ipa' },
                         { 'key' => 'artifact2', 'value' => 'mapping.txt' }],
        'fileHashes' => { 'app.ipa' => sha256('ipa-content'), 'mapping.txt' => sha256('mapping-content') }
      )
    end

    it 'prints the hash summary table' do
      run = run_main(root, env)
      expect(run.out).to include('ARTIFACT HASH SUMMARY (SHA256)')
      expect(run.out).to include(sha256('ipa-content'))
      expect(run.out).to include('uploaded : 2 file(s), 26 B')
      expect(run.out).to include('skipped  : 0 file(s)')
    end

    it 'writes the ac_chunk_N temp files to the working directory' do
      run = run_main(root, env)
      expect(File.read(File.join(run.root, 'ac_chunk_1'))).to eq('ipa-content')
      expect(File.read(File.join(run.root, 'ac_chunk_2'))).to eq('mapping-content')
    end

    it 'sends AC_TOKEN_ID as agentSecret without printing it' do
      run = run_main(root, env.merge('AC_TOKEN_ID' => 'super-secret-token'))
      expect(run.exitstatus).to eq(0)
      expect(run.chunk_fields).to all(include('agentSecret' => 'super-secret-token'))
      expect(run.complete_body['agentSecret']).to eq('super-secret-token')
      expect(run.out + run.err).not_to include('super-secret-token')
    end
  end

  context 'positive – discovery' do
    it 'uploads a single file when AC_UPLOAD_DIR points at a file' do
      file = write_file(File.join(upload, 'only.aab'), 'aab')
      write_file(File.join(upload, 'ignored.txt'), 'ignored')
      run = run_main(root, env.merge('AC_UPLOAD_DIR' => file))
      expect(run.exitstatus).to eq(0)
      expect(run.out).to include('upload path is a file')
      expect(run.chunk_fields.map { |f| f['filename'] }).to eq(['only.aab'])
    end

    it 'zips each subdirectory with the expected command and uploads the zip' do
      write_file(File.join(upload, 'reports', 'junit.xml'), '<xml/>')
      run = run_main(root, env)
      dir = File.join(upload, 'reports')
      expect(run.shell_commands).to eq([%(zip -r "#{dir}.zip" "#{dir}")])
      expect(run.chunk_fields.map { |f| f['filename'] }).to eq(['reports.zip'])
      expect(run.out).to include("zipping directory: #{dir}")
    end

    it 'completes with an empty file list for an empty folder' do
      FileUtils.mkdir_p(upload)
      run = run_main(root, env)
      expect(run.exitstatus).to eq(0)
      expect(run.out).to include('found 0 file(s) to upload')
      expect(run.out).not_to include('ARTIFACT HASH SUMMARY')
      expect(run.complete_body).to include('files' => [], 'fileHashes' => {})
    end

    it 'truncates file names longer than 40 characters in the summary table' do
      name = "#{'a' * 45}.apk"
      write_file(File.join(upload, name), 'x')
      run = run_main(root, env)
      expect(run.out).to include("#{'a' * 37}...")
      expect(run.complete_body['files'].first['value']).to eq(name)
    end

    it 'splits a file larger than 100 MB into 100 MB chunks with running offsets' do
      big = File.join(upload, 'big.bin')
      FileUtils.mkdir_p(upload)
      File.open(big, 'wb') { |f| f.truncate(100_000_001) }

      run = run_main(root, env)

      expect(run.exitstatus).to eq(0)
      expect(run.chunk_fields.map { |f| [f['offset'], f['fileSize']] })
        .to eq([['0', '100000000'], ['100000000', '1']])
      expect(run.chunk_fields.map { |f| f['name'] }.uniq).to eq(['artifact1'])
      expect(run.out).to include('chunk 1/2').and include('chunk 2/2')
      expect(run.complete_body['fileHashes']['big.bin']).to eq(Digest::SHA256.file(big).hexdigest.upcase)
    end
  end

  context 'negative' do
    it 'skips 0-byte files and leaves them out of the complete request' do
      write_file(File.join(upload, 'empty.txt'), '')
      write_file(File.join(upload, 'real.txt'), 'real')
      run = run_main(root, env)
      expect(run.exitstatus).to eq(0)
      expect(run.out).to include("SKIPPED : file size is 0 byte (#{File.join(upload, 'empty.txt')})")
      expect(run.out).to include('skipped  : 1 file(s)')
      expect(run.complete_body['files']).to eq([{ 'key' => 'artifact1', 'value' => 'real.txt' }])
      expect(run.complete_body['fileHashes'].keys).to eq(['real.txt'])
    end

    it "omits agentSecret when AC_TOKEN_ID is blank" do
      write_file(File.join(upload, 'a.txt'), 'a')
      run = run_main(root, env.merge('AC_TOKEN_ID' => '   '))
      expect(run.chunk_fields.first).not_to have_key('agentSecret')
      expect(run.complete_body).not_to have_key('agentSecret')
    end

    it 'retries a failing chunk and succeeds on the third attempt' do
      write_file(File.join(upload, 'a.txt'), 'a-content')
      run = run_main(root, env, chunk_statuses: '500,502')
      expect(run.exitstatus).to eq(0)
      expect(run.chunks.map { |c| c['status'] }).to eq([500, 502, 200])
      expect(run.chunk_fields.map { |f| f['chunk']['size'] }).to all(eq(9))
      expect(run.out).to include('attempt 1/3  FAILED').and include('retrying (2 attempt(s) left)')
      expect(run.out).to include('attempt 3/3  SUCCESS')
    end

    it 'fails the step after three failed chunk attempts and names the file' do
      write_file(File.join(upload, 'a.txt'), 'a-content')
      run = run_main(root, env, chunk_statuses: '500,500,500')
      expect(run.exitstatus).not_to eq(0)
      expect(run.chunks.size).to eq(3)
      expect(run.completes).to be_empty
      expect(run.out).to include('no attempts left, giving up')
      expect(run.out).to include('EXPORT BUILD ARTIFACTS FAILED')
      expect(run.out).to include('file   : a.txt')
      expect(run.out).to include('reason : HTTP 500 sandbox error')
    end

    it 'retries a failing complete request and succeeds' do
      write_file(File.join(upload, 'a.txt'), 'a')
      run = run_main(root, env, complete_statuses: '503')
      expect(run.exitstatus).to eq(0)
      expect(run.completes.map { |c| c['status'] }).to eq([503, 200])
      expect(run.out).to include('complete upload  attempt 2/3  SUCCESS')
    end

    it 'fails the step after three failed complete attempts without naming a file' do
      write_file(File.join(upload, 'a.txt'), 'a')
      run = run_main(root, env, complete_statuses: '503,503,503')
      expect(run.exitstatus).not_to eq(0)
      expect(run.completes.size).to eq(3)
      expect(run.out).to include('EXPORT BUILD ARTIFACTS FAILED')
      expect(run.out).to include('reason : HTTP 503 sandbox error')
      expect(run.out).not_to include('file   :')
    end

    it 'treats a 3xx response as a failure' do
      write_file(File.join(upload, 'a.txt'), 'a')
      run = run_main(root, env, chunk_statuses: '302,302,302')
      expect(run.exitstatus).not_to eq(0)
      expect(run.out).to include('reason : HTTP 302')
    end

    it 'refuses to talk to any host other than the configured one' do
      write_file(File.join(upload, 'a.txt'), 'a')
      run = run_main(root, env.merge('AC_UPLOADCHUNK_URL' => 'https://elsewhere.example.test/chunk'))
      expect(run.exitstatus).not_to eq(0)
      expect(run.out).to include('sandbox: network blocked for host "elsewhere.example.test"')
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
# Lines executed in-process (function tests) and in the main.rb subprocesses
# (collected by the sandbox) are merged, so the guarded top-level code counts.
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') && p == MAIN_RB }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data = result[main_path].dup
  $subprocess_coverage&.each_with_index do |count, i|
    next if count.nil?

    data[i] = data[i].to_i + count
  end

  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report (in-process + subprocess runs)'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
