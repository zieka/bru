#!/usr/bin/env ruby
# bru post_install harness — Homebrew runtime stub for whole-class evaluation.
#
# Reads ARGV[0] as a path to a Homebrew formula .rb file, evaluates the entire
# class definition under stubbed Homebrew DSL macros, locates the resulting
# Formula subclass, and invokes its post_install method.
#
# Required env: HOMEBREW_PREFIX, HOMEBREW_CELLAR, HOMEBREW_FORMULA_PREFIX,
# BRU_FORMULA_NAME, BRU_FORMULA_VERSION
# Exit status: 0 on success, 1 on post_install error, 2 on class-load error.

require "pathname"
require "fileutils"
require "tempfile"
require "set"

# Pathname extensions that real Homebrew adds globally.
class Pathname
  alias_method :to_str, :to_s unless method_defined?(:to_str)

  def mkpath
    FileUtils.mkdir_p(to_s)
  end

  def rmtree
    FileUtils.rm_rf(to_s)
  end

  def exist?
    File.exist?(to_s)
  end

  def atomic_write(content)
    parent = dirname.to_s
    FileUtils.mkdir_p(parent)
    Tempfile.open([basename.to_s, ""], parent) do |t|
      t.write(content)
      t.close
      File.rename(t.path, to_s)
    end
  end

  # Symlink each given source INTO this directory using the source basename.
  def install_symlink(*paths)
    mkpath
    paths.flatten.each do |src|
      target = self / Pathname.new(src.to_s).basename
      target.unlink if target.symlink? || target.exist?
      File.symlink(src.to_s, target.to_s)
    end
  end
end

HOMEBREW_PREFIX = Pathname.new(ENV.fetch("HOMEBREW_PREFIX"))
HOMEBREW_CELLAR = Pathname.new(ENV.fetch("HOMEBREW_CELLAR"))
HOMEBREW_REPOSITORY = Pathname.new(ENV["HOMEBREW_REPOSITORY"] || HOMEBREW_PREFIX.to_s)
HOMEBREW_LIBRARY = HOMEBREW_REPOSITORY / "Library"

module OS
  def self.mac?
    RUBY_PLATFORM.include?("darwin")
  end

  def self.linux?
    RUBY_PLATFORM.include?("linux")
  end

  def self.kernel_name
    mac? ? "Darwin" : "Linux"
  end
end

module MacOS
  class Version < String
    def initialize(s = "15")
      super(s)
    end

    def >=(_other)
      true
    end

    def >(_other)
      true
    end

    def <=(_other)
      false
    end

    def <(_other)
      false
    end

    def to_sym
      to_s.to_sym
    end
  end

  def self.version
    Version.new("15")
  end

  def self.full_version
    version
  end

  def self.sdk_path
    Pathname.new("/")
  end
end

module Hardware
  module CPU
    def self.arch
      RUBY_PLATFORM =~ /arm|aarch/ ? :arm64 : :x86_64
    end

    def self.intel?
      arch == :x86_64
    end

    def self.arm?
      arch == :arm64
    end

    def self.is_64_bit?
      true
    end

    def self.type
      arm? ? :arm : :intel
    end
  end
end

module DevelopmentTools
  # Return a high build version so version-gate checks like
  # `if DevelopmentTools.clang_build_version <= 1699` evaluate to false.
  def self.clang_build_version
    9999
  end

  def self.gcc_4_2_build_version
    9999
  end

  def self.curl_handles_most_https_certificates?
    true
  end
end

class ErrorDuringExecution < RuntimeError; end

# Homebrew Utils — wrappers around subprocess execution. We provide just enough
# for post_install bodies that call Utils.safe_popen_read / safe_popen_write.
module Utils
  def self.safe_popen_read(*cmd, &block)
    out = IO.popen(cmd.map(&:to_s), &:read)
    raise ErrorDuringExecution, "popen_read #{cmd.inspect} failed" unless $?.success?
    out
  end

  def self.popen_read(*cmd, &block)
    IO.popen(cmd.map(&:to_s), &:read)
  end

  # Open a subprocess with bidirectional pipes; the block writes to stdin and
  # the captured stdout is returned. Matches Homebrew's Utils.safe_popen_write
  # contract (block return value is ignored; the subprocess output is what
  # callers want).
  def self.safe_popen_write(*cmd, &block)
    out = nil
    IO.popen(cmd.map(&:to_s), "r+") do |io|
      block.call(io) if block
      io.close_write
      out = io.read
    end
    raise ErrorDuringExecution, "popen_write #{cmd.inspect} failed" unless $?.success?
    out
  end

  def self.popen_write(*cmd, &block)
    out = nil
    IO.popen(cmd.map(&:to_s), "r+") do |io|
      block.call(io) if block
      io.close_write
      out = io.read
    end
    out
  end
end

# Stub for `Formula["name"]` lookups inside post_install.
class FormulaStub
  attr_reader :name

  def initialize(name)
    @name = name.to_s
    @cellar_dir = HOMEBREW_CELLAR / @name
  end

  def prefix
    return @cellar_dir / "unknown" unless @cellar_dir.directory?
    versions = @cellar_dir.children.select(&:directory?)
    versions.max_by { |p| p.basename.to_s } || (@cellar_dir / "unknown")
  end

  def bin
    prefix / "bin"
  end

  def lib
    prefix / "lib"
  end

  def libexec
    prefix / "libexec"
  end

  def share
    prefix / "share"
  end

  def opt_prefix
    HOMEBREW_PREFIX / "opt" / @name
  end

  def opt_bin
    opt_prefix / "bin"
  end

  def opt_lib
    opt_prefix / "lib"
  end

  def opt_libexec
    opt_prefix / "libexec"
  end

  def opt_share
    opt_prefix / "share"
  end

  def pkgshare
    share / @name
  end

  def pkgetc
    HOMEBREW_PREFIX / "etc" / @name
  end

  def to_s
    @name
  end

  def to_str
    @name
  end

  def method_missing(_name, *_args, **_kwargs, &_block); end

  def respond_to_missing?(_name, _priv = false)
    true
  end
end

# Homebrew adds many helpers to ENV. Stub the ones formulas reach for.
module HomebrewEnvAdditions
  def cflags
    self["HOMEBREW_CFLAGS"] || ""
  end

  def cppflags
    self["HOMEBREW_CPPFLAGS"] || ""
  end

  def ldflags
    self["HOMEBREW_LDFLAGS"] || ""
  end

  def cc
    self["HOMEBREW_CC"] || "clang"
  end

  def cxx
    self["HOMEBREW_CXX"] || "clang++"
  end

  def make_jobs
    (self["HOMEBREW_MAKE_JOBS"] || "1").to_i
  end

  def prepend_create_path(_var, _path); end
  def prepend_path(_var, _path); end
  def append_path(_var, _path); end
  def deparallelize; end
end
ENV.singleton_class.prepend(HomebrewEnvAdditions)

# The Formula superclass that user formulas inherit from.
# Class-level method_missing absorbs all metadata macros (depends_on, url, etc.)
# so the class loads. Instance methods provide the path/exec helpers post_install
# bodies actually call.
class FormulaBase
  attr_reader :name, :version

  def initialize(name, version, formula_prefix)
    @name = name
    @version = version
    @prefix = Pathname.new(formula_prefix)
  end

  # Path methods.
  def prefix
    @prefix
  end

  def bin
    @prefix / "bin"
  end

  def sbin
    @prefix / "sbin"
  end

  def lib
    @prefix / "lib"
  end

  def libexec
    @prefix / "libexec"
  end

  def share
    @prefix / "share"
  end

  def etc
    HOMEBREW_PREFIX / "etc"
  end

  def var
    HOMEBREW_PREFIX / "var"
  end

  def include
    @prefix / "include"
  end

  def man
    share / "man"
  end

  def opt_prefix
    HOMEBREW_PREFIX / "opt" / @name
  end

  def opt_bin
    opt_prefix / "bin"
  end

  def opt_lib
    opt_prefix / "lib"
  end

  def opt_libexec
    opt_prefix / "libexec"
  end

  def opt_share
    opt_prefix / "share"
  end

  def buildpath
    @prefix
  end

  def testpath
    Pathname.new("/tmp") / "bru-test-#{@name}"
  end

  def pkgshare
    share / @name
  end

  def pkgetc
    etc / @name
  end

  def pkglog
    var / "log" / @name
  end

  # Subprocess wrapper — coerce Pathname args to String, raise on non-zero exit.
  def system(*args)
    flat = args.flatten.map(&:to_s)
    Kernel.system(*flat) or raise "system #{flat.inspect} failed"
  end

  # Like system but suppresses output and never raises. Used for best-effort
  # operations like killing background daemons during post_install.
  def quiet_system(*args)
    flat = args.flatten.map(&:to_s)
    pid = Process.spawn(*flat, out: File::NULL, err: File::NULL)
    Process.wait(pid)
    $?.success?
  end

  # FileUtils-style operations.
  def mkdir_p(*paths)
    FileUtils.mkdir_p(paths.flatten.map(&:to_s))
  end

  def rm_r(*paths)
    FileUtils.rm_rf(paths.flatten.map(&:to_s))
  end

  def rm_rf(*paths)
    FileUtils.rm_rf(paths.flatten.map(&:to_s))
  end

  def rm(*paths)
    paths.flatten.each { |p| File.unlink(p.to_s) rescue nil }
  end

  def rm_f(*paths)
    paths.flatten.each { |p| File.unlink(p.to_s) rescue nil }
  end

  def cp_r(src, dst)
    FileUtils.cp_r(src.to_s, dst.to_s)
  end

  def cp(src, dst)
    FileUtils.cp(src.to_s, dst.to_s)
  end

  def chmod(mode, path)
    FileUtils.chmod(mode, path.to_s)
  end

  def chmod_R(mode, path)
    FileUtils.chmod_R(mode, path.to_s)
  end

  def touch(*paths)
    FileUtils.touch(paths.flatten.map(&:to_s))
  end

  def mv(src, dst)
    FileUtils.mv(src.to_s, dst.to_s)
  end

  # ln_sf supports BOTH (single src, dst) and (array-of-srcs, dst-dir).
  def ln_sf(src, dst)
    sources = src.is_a?(Array) ? src : [src]
    sources.each do |s|
      FileUtils.ln_sf(s.to_s, dst.to_s)
    end
  end

  def ln_s(src, dst)
    FileUtils.ln_s(src.to_s, dst.to_s)
  end

  # Output helpers.
  def ohai(msg)
    warn("==> #{msg}")
  end

  def opoo(msg)
    warn("Warning: #{msg}")
  end

  def onoe(msg)
    warn("Error: #{msg}")
  end

  def odebug(msg)
    warn("[DEBUG] #{msg}") if ENV["HOMEBREW_VERBOSE"]
  end

  # Block-form platform conditions at instance scope.
  def on_macos
    yield if block_given? && OS.mac?
  end

  def on_linux
    yield if block_given? && OS.linux?
  end

  def on_arm
    yield if block_given? && Hardware::CPU.arm?
  end

  def on_intel
    yield if block_given? && Hardware::CPU.intel?
  end

  # which: locate an executable on PATH.
  def which(cmd)
    ENV["PATH"].to_s.split(":").each do |dir|
      candidate = File.join(dir, cmd.to_s)
      return Pathname.new(candidate) if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end

  # In-place file edit. Supports block form and (path, before, after) form.
  def inreplace(paths, before = nil, after = nil, &block)
    Array(paths).each do |path|
      contents = File.read(path.to_s)
      if block_given?
        wrapper = InreplaceWrapper.new(contents)
        block.call(wrapper)
        contents = wrapper.value
      elsif before.is_a?(Regexp)
        contents = contents.gsub(before, after.to_s)
      else
        contents = contents.gsub(before.to_s, after.to_s)
      end
      File.write(path.to_s, contents)
    end
  end

  class InreplaceWrapper
    attr_accessor :value
    def initialize(s)
      @value = s
    end

    def gsub!(a, b)
      @value = @value.gsub(a, b)
    end

    def sub!(a, b)
      @value = @value.sub(a, b)
    end

    def []=(a, b)
      @value[a] = b
    end
  end

  # Class-level DSL: catch every metadata macro so the formula class loads.
  class << self
    def method_missing(_name, *_args, **_kwargs, &_block); end

    def respond_to_missing?(_name, _priv = false)
      true
    end

    # Block-accepting macros: swallow without yielding.
    %i[
      bottle livecheck patch resource service test stable head devel
      head_only fails_with go_resource
    ].each do |sym|
      define_method(sym) { |*_a, **_kw, &_b| }
    end

    # Class-scope platform conditions — yield the block so the metadata calls
    # inside it (`depends_on`, etc.) can run and be absorbed by method_missing.
    %i[on_macos on_linux on_arm on_intel on_arm64 on_x86_64
       on_ventura on_sonoma on_sequoia on_tahoe on_monterey on_big_sur].each do |sym|
      define_method(sym) do |*_a, **_kw, &block|
        block&.call
      end
    end
  end
end

# Make `Formula` usable as both a constant lookup helper (`Formula["name"]`)
# and a superclass (`class Foo < Formula`). The class form aliases FormulaBase.
module FormulaLookup
  def self.[](name)
    FormulaStub.new(name)
  end
end

# Replace the Formula module with the FormulaBase class, but expose `[]`
# via singleton method so `Formula["name"]` keeps working.
remove_const(:Formula) if defined?(Formula)
Formula = FormulaBase
def Formula.[](name)
  FormulaStub.new(name)
end

rb_path = ARGV[0] or abort("usage: post_install_harness.rb <formula.rb>")
formula_name = ENV.fetch("BRU_FORMULA_NAME") { File.basename(rb_path, ".rb").split("-").first }
formula_version = ENV["BRU_FORMULA_VERSION"] || ""
formula_prefix = ENV.fetch("HOMEBREW_FORMULA_PREFIX")

source = File.read(rb_path)

class_name = source[/^class\s+([A-Z][A-Za-z0-9_]*)\s*<\s*Formula\b/, 1]
abort("could not find Formula class declaration in #{rb_path}") unless class_name

begin
  TOPLEVEL_BINDING.eval(source, rb_path)
rescue StandardError, ScriptError => e
  warn "post_install harness: failed to load formula source: #{e.class}: #{e.message}"
  warn e.backtrace.first(15).join("\n") if e.backtrace
  exit 2
end

klass = Object.const_get(class_name)
abort("loaded class #{class_name} is not a Formula subclass") unless klass.ancestors.include?(FormulaBase)

instance = klass.new(formula_name, formula_version, formula_prefix)
begin
  instance.post_install
rescue StandardError => e
  warn "post_install failed: #{e.class}: #{e.message}"
  warn e.backtrace.first(15).join("\n") if e.backtrace
  exit 1
end
