# typed: strict
# frozen_string_literal: true

require "env_config"
require "hardware"
require "utils/popen"

module Timed
  # What an LLM is told of this machine and how brew builds on it: hardware
  # and setup facts only, never a host name, user name, serial number or
  # path. Each is left out when it can't be read, as the request is never
  # worth stopping the run for.
  module Machine
    # What the estimate is for, as the build log measures it.
    TIMED = "wall-clock seconds for brew to build and install the formula alone from source: configure, compile, " \
            "test steps run during install, installing its resources (e.g. Python packages) and linking; not " \
            "downloads and not its dependencies, which are already installed"
    # Read in one call, which leaves out any this Mac doesn't have.
    SYSCTLS = %w[machdep.cpu.brand_string hw.physicalcpu hw.logicalcpu hw.nperflevels hw.perflevel0.physicalcpu
                 hw.perflevel1.physicalcpu hw.model kern.hv_vmm_present hw.memsize].freeze
    # SMBIOS chassis types.
    FORMS = T.let({ "laptop" => [8, 9, 10, 14, 31, 32], "desktop" => [3, 4, 6, 7, 13, 15, 35],
                    "server" => [17, 23, 28] }.freeze, T::Hash[String, T::Array[Integer]])

    # The facts in the prompt's order, from `sysctl` on macOS and `/proc`,
    # `/sys` and (on ARM, when those don't name the CPU) `lscpu` on Linux.
    # `run` gives a command's output and `read` a file's; either may raise.
    # Commands run in the C locale, for `lscpu`'s English headings, with
    # stderr closed, so a missing command isn't reported.
    sig {
      params(mac: T::Boolean, run: T.proc.params(argv: T::Array[String]).returns(String),
             read: T.proc.params(path: String).returns(String))
        .returns(T::Hash[String, T.any(String, Integer, Float, T::Boolean)])
    }
    def self.facts(mac: OS.mac?, run: ->(argv) { Utils.popen_read({ "LC_ALL" => "C" }, *argv, err: :close) },
                   read: ->(path) { File.read(path) })
      output = ->(argv) { quietly { utf8(run.call(argv)) } }
      sysctl = (mac ? output.call(["/usr/sbin/sysctl", *SYSCTLS]).to_s : "").lines.filter_map do |line|
        name, value = line.chomp.split(": ", 2)
        [name, value] if value
      end.to_h
      # Each file is read at most once, and is `nil` if it can't be.
      files = Hash.new { |read_files, path| read_files[path] = quietly { utf8(read.call(path)) } }
      cpuinfo = -> { files["/proc/cpuinfo"].to_s }
      perf_levels = count(sysctl["hw.nperflevels"]).to_i
      facts = {
        "cpu"               => lambda do
          next sysctl["machdep.cpu.brand_string"] if mac

          cpuinfo.call[/^model name\s*:(.*)$/, 1].presence ||
            output.call(["lscpu"]).to_s[/^Model name:(.*)$/, 1].presence ||
            files["/sys/firmware/devicetree/base/model"]&.delete("\0")
        end,
        "arch"              => -> { Hardware::CPU.arch.to_s },
        "physical_cores"    => lambda do
          next count(sysctl["hw.physicalcpu"]) if mac

          cpuinfo.call.split(/\n\s*\n/).filter_map do |entry|
            ids = [entry[/^physical id\s*:\s*(\S+)/, 1], entry[/^core id\s*:\s*(\S+)/, 1]]
            ids if ids.all?
          end.uniq.size.nonzero?
        end,
        "threads"           => -> { mac ? count(sysctl["hw.logicalcpu"]) : Hardware::CPU.cores },
        "performance_cores" => -> { count(sysctl["hw.perflevel0.physicalcpu"]) if perf_levels > 1 },
        "efficiency_cores"  => -> { count(sysctl["hw.perflevel1.physicalcpu"]) if perf_levels > 1 },
        # A container's cgroup v2 quota over period, when it has one.
        "cpu_limit"         => lambda do
          next if mac

          quota, period = files["/sys/fs/cgroup/cpu.max"].to_s.split.map { Float(it, exception: false) }
          (quota / period).round(2) if quota&.positive? && period&.positive?
        end,
        "model"             => -> { mac ? sysctl["hw.model"] : files["/sys/class/dmi/id/product_name"] },
        "form"              => lambda do
          next ("laptop" if sysctl["hw.model"]&.include?("Book")) if mac

          chassis = count(files["/sys/class/dmi/id/chassis_type"])
          FORMS.find { |_, types| types.include?(chassis) }&.first
        end,
        "virtualised"       => lambda do
          next { "1" => true, "0" => false }[sysctl["kern.hv_vmm_present"]] if mac

          flags = cpuinfo.call[/^flags\s*:(.*)$/, 1]&.split
          # WSL by its kernel release, as `OS.wsl?` checks it.
          release = files["/proc/version"].to_s[/\ALinux version (\S+)/, 1]
          if flags&.include?("hypervisor") || release.to_s.match?(/-microsoft/i)
            true
          elsif flags
            false
          end
        end,
        "memory_gb"         => lambda do
          bytes = if mac
            count(sysctl["hw.memsize"])
          else
            count(files["/proc/meminfo"].to_s[/^MemTotal:\s*(\d+) kB$/, 1])&.*(1024)
          end
          (bytes / (1024.0**3)).round if bytes
        end,
        "os"                => -> { OS_VERSION },
        "make_jobs"         => -> { count(Homebrew::EnvConfig.make_jobs) },
        "timed"             => -> { TIMED },
      }
      facts.filter_map do |name, fact|
        value = quietly { fact.call.then { it.is_a?(String) ? it.split.join(" ").presence : it } }
        [name, value] unless value.nil?
      end.to_h
    end

    # A whole number over 0, or none.
    sig { params(text: T.nilable(String)).returns(T.nilable(Integer)) }
    private_class_method def self.count(text)
      number = text.to_s.strip
      number.to_i if number.match?(/\A\d+\z/) && number.to_i.positive?
    end

    # Valid UTF-8, any other bytes replaced, so one stray byte can't cost the
    # rest of the facts or the request.
    sig { params(text: String).returns(String) }
    private_class_method def self.utf8(text) = text.dup.force_encoding(Encoding::UTF_8).scrub

    sig {
      type_parameters(:U).params(_block: T.proc.returns(T.type_parameter(:U)))
                         .returns(T.nilable(T.type_parameter(:U)))
    }
    private_class_method def self.quietly(&_block)
      yield
    rescue
      nil
    end
  end
end
