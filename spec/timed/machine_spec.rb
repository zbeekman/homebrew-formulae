# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "json"
require_relative "../../lib/timed/machine"

RSpec.describe Timed::Machine do
  let(:runs) { [] }
  let(:reads) { [] }
  # What every platform adds, from brew.
  let(:brew_facts) { { "os" => OS_VERSION, "make_jobs" => 6, "timed" => Timed::Machine::TIMED } }

  before do
    allow(Hardware::CPU).to receive_messages(arch: :x86_64, cores: 4)
    ENV["HOMEBREW_MAKE_JOBS"] = "6"
  end

  # The facts with `commands` as the output of each command by its name and
  # `files` as each file's contents by path; any other command or file is
  # missing, and an `Exception` is raised instead.
  def facts(mac:, commands: {}, files: {})
    run = lambda do |argv|
      runs << argv
      output = commands.fetch(File.basename(argv.fetch(0))) { Errno::ENOENT.new(argv.fetch(0)) }
      raise output if output.is_a?(Exception)

      output
    end
    read = lambda do |path|
      reads << path
      contents = files.fetch(path) { Errno::ENOENT.new(path) }
      raise contents if contents.is_a?(Exception)

      contents
    end
    described_class.facts(mac:, run:, read:)
  end

  # `/proc/cpuinfo` with one entry per thread: `sockets` × `cores` ×
  # `threads`, each with `fields` and, unless `ids` is false, its physical
  # and core id.
  def cpuinfo(fields, sockets: 1, cores: 1, threads: 1, ids: true)
    ids_by_thread = (0...sockets).to_a.product((0...cores).to_a, (0...threads).to_a)
    entries = ids_by_thread.each_with_index.map do |(socket, core, _), processor|
      lines = ["processor\t: #{processor}", *fields.map { |name, value| "#{name}\t: #{value}" }]
      lines += ["physical id\t: #{socket}", "core id\t\t: #{core}"] if ids
      lines.join("\n")
    end
    "#{entries.join("\n\n")}\n\n"
  end

  describe "on macOS" do
    let(:intel) do
      <<~EOS
        machdep.cpu.brand_string: Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz
        hw.physicalcpu: 8
        hw.logicalcpu: 16
        hw.nperflevels: 1
        hw.perflevel0.physicalcpu: 8
        hw.model: MacBookPro16,4
        kern.hv_vmm_present: 0
        hw.memsize: 34359738368
      EOS
    end

    it "describes an Intel Mac, a laptop by its model" do
      expect(facts(mac: true, commands: { "sysctl" => intel })).to eq(
        "cpu" => "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", "arch" => "x86_64", "physical_cores" => 8,
        "threads" => 16, "model" => "MacBookPro16,4", "form" => "laptop", "virtualised" => false,
        "memory_gb" => 32, **brew_facts
      )
    end

    it "reads it all with one `sysctl` and no files" do
      facts(mac: true, commands: { "sysctl" => intel })
      expect([runs, reads]).to eq([[["/usr/sbin/sysctl", *Timed::Machine::SYSCTLS]], []])
    end

    it "describes an Apple Silicon Mac with its performance and efficiency cores, and no form a model name " \
       "doesn't give" do
      allow(Hardware::CPU).to receive(:arch).and_return(:arm64)
      sysctl = <<~EOS
        machdep.cpu.brand_string: Apple M2 Pro
        hw.physicalcpu: 12
        hw.logicalcpu: 12
        hw.nperflevels: 2
        hw.perflevel0.physicalcpu: 8
        hw.perflevel1.physicalcpu: 4
        hw.model: Mac14,9
        kern.hv_vmm_present: 0
        hw.memsize: 17179869184
      EOS
      expect(facts(mac: true, commands: { "sysctl" => sysctl })).to eq(
        "cpu" => "Apple M2 Pro", "arch" => "arm64", "physical_cores" => 12, "threads" => 12,
        "performance_cores" => 8, "efficiency_cores" => 4, "model" => "Mac14,9", "virtualised" => false,
        "memory_gb" => 16, **brew_facts
      )
    end

    it "says a Mac is virtualised" do
      sysctl = "hw.model: VirtualMac2,1\nkern.hv_vmm_present: 1\n"
      expect(facts(mac: true, commands: { "sysctl" => sysctl })).to eq(
        "arch" => "x86_64", "model" => "VirtualMac2,1", "virtualised" => true, **brew_facts,
      )
    end

    it "leaves out what `sysctl` can't run or doesn't give as expected" do
      outputs = {
        "fails"   => Errno::ENOENT.new("/usr/sbin/sysctl"),
        "garbled" => "hw.physicalcpu: lots\nhw.logicalcpu:\nhw.model\nhw.memsize: -1\nkern.hv_vmm_present: 1 2\n" \
                     "hw.nperflevels: 2\n",
      }
      facts_by_output = outputs.to_h { |label, output| [label, facts(mac: true, commands: { "sysctl" => output })] }
      expect(facts_by_output).to eq(outputs.to_h { |label, _| [label, { "arch" => "x86_64", **brew_facts }] })
    end

    it "replaces bytes in `sysctl`'s output that aren't UTF-8, so the facts can still be sent" do
      sysctl = "machdep.cpu.brand_string: Apple M9 \xFF\nhw.model: Caf\xE9Book1,1\nhw.memsize: 17179869184\n".b
      expect(JSON.parse(JSON.generate(facts(mac: true, commands: { "sysctl" => sysctl })))).to eq(
        "cpu" => "Apple M9 \uFFFD", "arch" => "x86_64", "model" => "Caf\uFFFDBook1,1", "form" => "laptop",
        "memory_gb" => 16, **brew_facts
      )
    end
  end

  describe "on Linux" do
    let(:meminfo) { "MemTotal:       16273908 kB\nMemFree:         1234567 kB\n" }

    it "describes an x86_64 laptop" do
      cpu = "11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz"
      files = {
        "/proc/cpuinfo"                  => cpuinfo({ "model name" => cpu, "flags" => "fpu vme sse2 avx2" },
                                                    cores: 2, threads: 2),
        "/proc/meminfo"                  => meminfo,
        "/proc/version"                  => "Linux version 6.8.0-45-generic (buildd@lcy02-amd64-075) (gcc 13.2)\n",
        "/sys/class/dmi/id/product_name" => "XPS 13 9310\n",
        "/sys/class/dmi/id/chassis_type" => "10\n",
      }
      expect(facts(mac: false, files:)).to eq(
        "cpu" => cpu, "arch" => "x86_64", "physical_cores" => 2,
        "threads" => 4, "model" => "XPS 13 9310", "form" => "laptop", "virtualised" => false,
        "memory_gb" => 16, **brew_facts
      )
    end

    it "describes an x86_64 server VM with two sockets, in a container with a CPU limit" do
      files = {
        "/proc/cpuinfo"                  => cpuinfo({ "model name" => "AMD EPYC  7R13   Processor  ",
                                                      "flags"      => "fpu sse2 hypervisor avx2" },
                                                    sockets: 2, cores: 2, threads: 2),
        "/proc/meminfo"                  => meminfo,
        "/sys/class/dmi/id/product_name" => "PowerEdge R750\n",
        "/sys/class/dmi/id/chassis_type" => "23\n",
        "/sys/fs/cgroup/cpu.max"         => "250000 100000\n",
      }
      expect(facts(mac: false, files:)).to eq(
        "cpu" => "AMD EPYC 7R13 Processor", "arch" => "x86_64", "physical_cores" => 4, "threads" => 4,
        "cpu_limit" => 2.5, "model" => "PowerEdge R750", "form" => "server", "virtualised" => true,
        "memory_gb" => 16, **brew_facts
      )
    end

    it "describes an ARM server in a container by `lscpu`'s model name, which it runs only then" do
      allow(Hardware::CPU).to receive(:arch).and_return(:arm64)
      files = {
        "/proc/cpuinfo"                  => cpuinfo({ "BogoMIPS" => "243.75", "Features" => "fp asimd aes",
                                                      "CPU part" => "0xd0c" }, cores: 4, ids: false),
        "/proc/meminfo"                  => meminfo,
        "/sys/class/dmi/id/product_name" => "c6g.xlarge\n",
        "/sys/class/dmi/id/chassis_type" => "1\n",
        "/sys/fs/cgroup/cpu.max"         => "max 100000\n",
      }
      lscpu = "Architecture:             aarch64\nVendor ID:                ARM\nModel name:               " \
              "Neoverse-N1\nThread(s) per core:       1\n"
      expect([facts(mac: false, commands: { "lscpu" => lscpu }, files:), runs]).to eq(
        [{ "cpu" => "Neoverse-N1", "arch" => "arm64", "threads" => 4, "model" => "c6g.xlarge", "memory_gb" => 16,
           **brew_facts }, [["lscpu"]]],
      )
    end

    it "describes an ARM board without `lscpu` or a CPU model name by its device tree model" do
      allow(Hardware::CPU).to receive(:arch).and_return(:arm64)
      files = {
        "/proc/cpuinfo"                       => cpuinfo({ "model name" => " ", "Features" => "fp asimd" },
                                                         cores: 4, ids: false),
        "/sys/firmware/devicetree/base/model" => "Raspberry Pi 4 Model B Rev 1.4\u0000",
      }
      expect(facts(mac: false, files:)).to eq(
        "cpu" => "Raspberry Pi 4 Model B Rev 1.4", "arch" => "arm64", "threads" => 4, **brew_facts,
      )
    end

    it "says WSL 1 and 2 are virtualised by their kernel release alone, and reads a desktop from its chassis type" do
      virtualised_by_version = {
        "Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com) (gcc 5.4.0)\n"            => true,
        "Linux version 5.15.153.1-microsoft-standard-WSL2 (root@1234) (gcc)\n"                   => true,
        "Linux version 6.8.0-45-generic (dev@build-microsoft-01) (gcc 13.2) #45-Microsoft SMP\n" => false,
      }
      facts_by_version = virtualised_by_version.keys.to_h do |version|
        files = {
          "/proc/cpuinfo"                  => cpuinfo({ "model name" => "AMD Ryzen 9 7950X", "flags" => "fpu sse2" }),
          "/proc/version"                  => version,
          "/sys/class/dmi/id/chassis_type" => "3\n",
        }
        [version, facts(mac: false, files:)]
      end
      expect(facts_by_version).to eq(virtualised_by_version.to_h do |version, virtualised|
        [version, { "cpu" => "AMD Ryzen 9 7950X", "arch" => "x86_64", "physical_cores" => 1, "threads" => 4,
                    "form" => "desktop", "virtualised" => virtualised, **brew_facts }]
      end)
    end

    it "leaves out whatever is missing, unreadable or not as expected" do
      unreadable = Errno::EACCES.new("denied")
      sources = {
        "missing"    => [{}, {}],
        "unreadable" => [{ "lscpu" => unreadable }, {
          "/proc/cpuinfo" => unreadable, "/proc/meminfo" => unreadable, "/proc/version" => unreadable,
          "/sys/class/dmi/id/product_name" => unreadable, "/sys/class/dmi/id/chassis_type" => unreadable,
          "/sys/fs/cgroup/cpu.max" => unreadable, "/sys/firmware/devicetree/base/model" => unreadable
        }],
        "garbled"    => [{ "lscpu" => "Architecture: aarch64\n" }, {
          "/proc/cpuinfo" => "processor\t: 0\nphysical id\t: 0\n", "/proc/meminfo" => "MemFree: 1 kB\n",
          "/proc/version" => "", "/sys/class/dmi/id/product_name" => "  \n",
          "/sys/class/dmi/id/chassis_type" => "2\n", "/sys/fs/cgroup/cpu.max" => "0 100000\n",
          "/sys/firmware/devicetree/base/model" => "\u0000"
        }],
      }
      facts_by_source = sources.to_h do |label, (commands, files)|
        [label, facts(mac: false, commands:, files:)]
      end
      left = { "arch" => "x86_64", "threads" => 4, **brew_facts }
      expect(facts_by_source).to eq(sources.transform_values { left })
    end

    it "replaces bytes in files and `lscpu`'s output that aren't UTF-8, so the facts can still be sent" do
      files = {
        "/proc/cpuinfo"                  => cpuinfo({ "model name" => "Xeon\xFF", "flags" => "fpu hypervisor" },
                                                    cores: 2),
        "/proc/meminfo"                  => meminfo,
        "/sys/class/dmi/id/product_name" => "Caf\xE9 PC\n",
      }
      lscpu_files = { "/proc/cpuinfo" => cpuinfo({ "Features" => "fp" }, ids: false) }
      outcomes = {
        "files" => facts(mac: false, files:),
        "lscpu" => facts(mac: false, commands: { "lscpu" => "Model name: Neoverse \xFF\n".b }, files: lscpu_files),
      }
      expect(JSON.parse(JSON.generate(outcomes))).to eq(
        "files" => { "cpu" => "Xeon\uFFFD", "arch" => "x86_64", "physical_cores" => 2, "threads" => 4,
                     "model" => "Caf\uFFFD PC", "virtualised" => true, "memory_gb" => 16, **brew_facts },
        "lscpu" => { "cpu" => "Neoverse \uFFFD", "arch" => "x86_64", "threads" => 4, **brew_facts },
      )
    end

    it "reads only hardware and setup files: no serial number, host name or user name" do
      facts(mac: false)
      expect(reads.sort).to eq(%w[/proc/cpuinfo /proc/meminfo /proc/version /sys/class/dmi/id/chassis_type
                                  /sys/class/dmi/id/product_name /sys/firmware/devicetree/base/model
                                  /sys/fs/cgroup/cpu.max])
    end
  end

  it "leaves out a fact brew can't give, however it fails" do
    allow(Hardware::CPU).to receive(:arch).and_raise(RuntimeError, "no CPU")
    allow(Hardware::CPU).to receive(:cores).and_raise(ArgumentError, "none")
    allow(Homebrew::EnvConfig).to receive(:make_jobs).and_raise(IOError, "closed")
    expect(facts(mac: false)).to eq("os" => OS_VERSION, "timed" => Timed::Machine::TIMED)
  end

  it "describes this machine with known facts of the right types" do
    allow(Hardware::CPU).to receive(:arch).and_call_original
    allow(Hardware::CPU).to receive(:cores).and_call_original
    types = { "cpu" => String, "arch" => String, "physical_cores" => Integer, "threads" => Integer,
              "performance_cores" => Integer, "efficiency_cores" => Integer, "cpu_limit" => Float,
              "model" => String, "form" => String, "virtualised" => [TrueClass, FalseClass], "memory_gb" => Integer,
              "os" => String, "make_jobs" => Integer, "timed" => String }
    found = described_class.facts.to_h { |name, value| [name, Array(types[name]).include?(value.class)] }
    expect(found).to eq(found.keys.to_h { |name| [name, true] }).and include("arch", "threads", "os")
  end
end
# rubocop:enable Sorbet/BlockMethodDefinition
