#!/usr/bin/ruby -w
#$Id$
#$URL$
$svn_exe = "svn"  # default assumes the program is in $PATH

def usage(msg)
  $stderr.puts(msg)
  exit(1)
end

$tmpdir = ENV["TMPDIR"] || "/tmp"
$dirtemplate = "svnspam.#{Process.getpgrp}.#{Process.uid}"
# arguments to pass though to 'svnspam.rb'
$passthrough_args = []

def make_data_dir
  dir = "#{$tmpdir}/#{$dirtemplate}-#{rand(99999999)}"
  Dir.mkdir(dir, 0700)
  dir
end

def init
  $datadir = make_data_dir

  # set PWD
  Dir.chdir($datadir)
end

def cleanup
  File.unlink("#{$datadir}/logfile")
  Dir.rmdir($datadir)
end

def send_email
  cmd = File.dirname($0) + "/svnspam.rb"
  unless system(cmd, "#{$datadir}/logfile", *$passthrough_args)
    fail "problem running '#{cmd}'"
  end
end

# Like IO.popen, but accepts multiple arguments like Kernel.exec
# (So no need to escape shell metacharacters)
def safer_popen(*args)
  IO.popen("-") do |pipe|
    if pipe==nil
      exec(*args)
    else
      yield pipe
    end
  end
end

# Process the command-line arguments in the given list
def process_args
  require 'getoptlong'

  opts = GetoptLong.new(
    [ "--to",     "-t", GetoptLong::REQUIRED_ARGUMENT ],
    [ "--config", "-c", GetoptLong::REQUIRED_ARGUMENT ],
    [ "--debug",  "-d", GetoptLong::NO_ARGUMENT ],
    [ "--help",   "-h", GetoptLong::NO_ARGUMENT ],
    [ "--from",   "-u", GetoptLong::REQUIRED_ARGUMENT ],
    [ "--repository", "-r", GetoptLong::REQUIRED_ARGUMENT ],
    [ "--charset",      GetoptLong::REQUIRED_ARGUMENT ]
  )

  opts.each do |opt, arg|
    if ["--to", "--config", "--from", "--charset", "--repository"].include?(opt)
      $passthrough_args << opt << arg
    end
    if ["--debug"].include?(opt)
      $passthrough_args << opt
    end
    $config = arg if opt=="--config"
    $debug = true if opt == "--debug"
    usage(" {repository} {revision} [{previous revision}]") if opt=="--help"
  end

  $repository = ARGV.shift
  $revision = ARGV.shift
  unless $revision =~ /^\d+$/
    usage("revision must be an integer: #{revision.inspect}")
  end
  $revision = $revision.to_i

  $prev_revision = ARGV.shift || ($revision - 1)
  $prev_revision = $prev_revision.to_i

end

# runs the given svn subcommand
def svnexe(cmd, revision, *args)
  safer_popen($svn_exe, cmd, $repository, "-r", revision.to_s, *args) do |io|
    yield io
  end
end

# Line-oriented access to an underlying IO object.  Remembers 'current' line
# for lookahead during parsing.
class LineReader
  def initialize(io)
    @io = io
    @hold = 0
  end

  def current
    @line
  end

  def current_valid
    return @line != nil
  end

  def next_line
    if( @hold != 0 )
      @hold = @hold - 1
      return true
    else
      (@line = @io.gets) != nil
    end
  end

  def hold
    @hold = @hold + 1
  end

  def assert_next(re=nil)
    raise "unexpected end of text" unless next_line
    unless re.nil?
      raise "unexpected #{current.inspect}" unless @line =~ re
    end
    $~
  end
end

def read_diff(out, lines, path)
  lines.assert_next(/^=+$/)
  lines.next_line
  diff1 = lines.current
  match1 = diff1.match(/^---.*\(revision (\d+)\)$/)
  if match1
    lines.next_line
    diff2 = lines.current
    match2 = diff2.match(/^\+\+\+.*\(revision (\d+)\)$/)
    if match2
      prev_rev = match1.captures[0].to_i
      next_rev = match2.captures[0].to_i
      out.puts "#V #{prev_rev},#{next_rev}"
      out.puts "#M #{path}"
      out.puts "#U #{diff1}"
      out.puts "#U #{diff2}"
    else
      out.puts "#V #{$prev_revision},#{$revision}"
      out.puts "#M #{path}"
      out.puts "#U #{diff1}"
    end
  else
    out.puts "#V #{$prev_revision},#{$revision}"
    out.puts "#M #{path}"
  end
  while lines.next_line && lines.current !~ /^Index:\s+(.*)/
    out.puts "#U #{lines.current}"
  end
end

def process_svn_log(file)
  svnexe("log", ($prev_revision + 1).to_s+":"+$revision.to_s) do |io|
    io.each_line do |line|
      file.puts("#> #{line}")
    end
  end
end

def process_svn_diff(file)
  svnexe("diff", $prev_revision.to_s+':'+$revision.to_s ) do |diff_io|
    diff_lines = LineReader.new(diff_io)
    while diff_lines.next_line
      if diff_lines.current =~ /^Index:\s+(.*)/
        read_diff(file, diff_lines, $1)
        if diff_lines.current_valid
            diff_lines.hold
        end
      end
    end
  end
end

def process_commit()
    File.open("#{$datadir}/logfile", File::WRONLY|File::CREAT) do |file|
      process_svn_log(file)
      process_svn_diff(file)
    end
end

def main
  init()
  process_args()
  process_commit()
  send_email()
  cleanup()
end

main
