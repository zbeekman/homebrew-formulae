class Cgns < Formula
  desc "CFD General Notation System"
  homepage "http://cgns.org/"
  url "https://github.com/CGNS/CGNS/archive/v3.3.1.tar.gz"
  sha256 "81093693b2e21a99c5640b82b267a495625b663d7b8125d5f1e9e7aaa1f8d469"
  revision 1

  depends_on "cmake" => :build
  depends_on "gcc"
  depends_on "szip"
  depends_on "hdf5"


  def install
    args = std_cmake_args + [
      "-DCGNS_ENABLE_TESTS=YES",
    ]

    args << "-DCGNS_ENABLE_64BIT=YES" if Hardware::CPU.is_64_bit? && MacOS.version >= :snow_leopard
    args << "-DCGNS_ENABLE_FORTRAN=YES"

    if build.with? "hdf5"
      args << "-DCGNS_ENABLE_HDF5=YES"
      args << "-DHDF5_NEED_ZLIB=YES"
      args << "-DHDF5_NEED_SLIB=YES"
      args << "-DCMAKE_SHARED_LINKER_FLAGS=-lhdf5"
    end

    mkdir "build" do
      system "cmake", "..", *args
      system "make"
      system "ctest", "--output-on-failure"
      system "make", "install"
    end
  end

  test do
    (testpath/"test.c").write <<-EOS.undent
      #include <stdio.h>
      #include "cgnslib.h"
      int main(int argc, char *argv[])
      {
        int filetype = CG_FILE_NONE;
        // we expect this to fail, as the test executable isn't a CGNS file
        if (cg_is_cgns(argv[0], &filetype) != CG_ERROR)
          return 1; // should fail!
        printf(\"%d.%d.%d\\n\",CGNS_VERSION/1000,(CGNS_VERSION/100)%10,(CGNS_VERSION/10)%10);
        return 0;
      }
    EOS
    compiler = Tab.for_name("cgns").with?("hdf5") ? "h5cc" : ENV.cc
    # The rpath to szip needs to be passed explicitely here because the
    # compiler may be h5cc (Superenv is not supported in that case)
    rpath = "-Wl,-rpath=#{Formula["szip"].opt_lib}" unless OS.mac?
    system compiler, "-I#{opt_include}", testpath/"test.c", "-L#{opt_lib}", "-lcgns", *rpath
    assert_match(/#{version}/, shell_output("./a.out"))
  end
end
