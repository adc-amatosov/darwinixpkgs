{ pkgspath ? ../../.., test-pkgspath ? pkgspath, system ? builtins.currentSystem }:

with import pkgspath { inherit system; };

let
  llvmPackages = llvmPackages_39;
in rec {
  coreutils_ = coreutils.override (args: {
    # We want coreutils without ACL support.
    aclSupport = false;
    # Cannot use a single binary build, or it gets dynamically linked against gmp.
    singleBinary = false;
  });

  # Avoid debugging larger changes for now.
  bzip2_ = bzip2.override (args: { linkStatic = true; });

  build = stdenv.mkDerivation {
    name = "stdenv-bootstrap-tools";

    buildInputs = [nukeReferences cpio];

    buildCommand = ''
      mkdir -p $out/bin $out/lib $out/include

      chmod -R u+w $out/include

      cp -rL ${icu.dev}/include* $out/include
      cp -rL ${libiconv}/include/* $out/include
      cp -rL ${gnugrep.pcre.dev}/include/* $out/include
      cp ${coreutils_}/bin/* $out/bin

      cp ${bash}/bin/bash $out/bin
      cp ${findutils}/bin/find $out/bin
      cp ${findutils}/bin/xargs $out/bin
      cp -d ${diffutils}/bin/* $out/bin
      cp -d ${gnused}/bin/* $out/bin
      cp -d ${gnugrep}/bin/grep $out/bin
      cp ${gawk}/bin/gawk $out/bin
      cp -d ${gawk}/bin/awk $out/bin
      cp ${gnutar}/bin/tar $out/bin
      cp ${gzip}/bin/gzip $out/bin
      cp ${bzip2_.bin}/bin/bzip2 $out/bin
      cp -d ${gnumake}/bin/* $out/bin
      cp -d ${patch}/bin/* $out/bin
      cp -d ${xz.bin}/bin/xz $out/bin
      cp ${curl.bin}/bin/curl $out/bin
      cp -d ${curl.out}/lib/libcurl*.dylib $out/lib
      cp -d ${libssh2.out}/lib/libssh*.dylib $out/lib
      cp -d ${openssl.out}/lib/*.dylib $out/lib

      for i in as ld ar ranlib nm strip otool install_name_tool dsymutil; do
        cp ${darwin.cctools}/bin/$i $out/bin
      done

      cp -d ${libcxx}/lib/libc++*.dylib $out/lib
      cp -d ${libcxxabi}/lib/libc++abi*.dylib $out/lib
      cp -d ${gnugrep.pcre.out}/lib/libpcre*.dylib $out/lib
      cp -d ${lib.getLib libiconv}/lib/lib*.dylib $out/lib
      cp -d ${gettext}/lib/libintl*.dylib $out/lib
      chmod +x $out/lib/libintl*.dylib
      cp -d ${ncurses.out}/lib/libncurses*.dylib $out/lib
      cp -d ${zlib.out}/lib/libz.*       $out/lib
      cp -d ${gmpxx.out}/lib/libgmp*.*   $out/lib
      cp -d ${xz.out}/lib/liblzma*.*     $out/lib

      cp -d ${llvmPackages.clang-unwrapped}/bin/clang $out/bin
      cp -d ${llvmPackages.clang-unwrapped}/bin/clang++ $out/bin
      cp -d ${llvmPackages.clang-unwrapped}/bin/clang-[0-9].[0-9] $out/bin

      cp -rL ${llvmPackages.clang-unwrapped}/lib/clang $out/lib

      cp -rd ${llvmPackages.libcxx}/include/c++     $out/include

      nuke-refs $out/bin/*
      nuke-refs $out/lib/*

      rpathify() {
        local libs=$(${darwin.cctools}/bin/otool -L "$1" | tail -n +2 | grep -o "$NIX_STORE.*-\S*") || true
        for lib in $libs; do
          ${darwin.cctools}/bin/install_name_tool -change $lib "@rpath/$(basename $lib)" "$1"
        done
      }

      chmod -R u+w $out

      nuke-refs $out/lib/clang/*/lib/darwin/*

      for i in $out/bin/* $out/lib/*.dylib $out/lib/clang/*/lib/darwin/*.dylib; do
        if test -x $i -a ! -L $i; then
          echo "Adding rpath to $i"
          rpathify $i
        fi
      done

      set -x
      mkdir $out/.pack
      mv $out/* $out/.pack
      mv $out/.pack $out/pack

      mkdir $out/on-server
      cp ${stdenv.shell} $out/on-server/sh
      cp ${cpio}/bin/cpio $out/on-server
      cp ${coreutils_}/bin/mkdir $out/on-server
      cp ${bzip2_.bin}/bin/bzip2 $out/on-server

      chmod u+w $out/on-server/*
      strip $out/on-server/*
      nuke-refs $out/on-server/*

      (cd $out/pack && (find | cpio -o -H newc)) | bzip2 > $out/on-server/bootstrap-tools.cpio.bz2
    '';

    allowedReferences = [];

    meta = {
      maintainers = [ stdenv.lib.maintainers.copumpkin ];
    };
  };

  dist = stdenv.mkDerivation {
    name = "stdenv-bootstrap-tools";

    buildCommand = ''
      mkdir -p $out/nix-support
      echo "file tarball ${build}/on-server/bootstrap-tools.cpio.bz2" >> $out/nix-support/hydra-build-products
      echo "file sh ${build}/on-server/sh" >> $out/nix-support/hydra-build-products
      echo "file cpio ${build}/on-server/cpio" >> $out/nix-support/hydra-build-products
      echo "file mkdir ${build}/on-server/mkdir" >> $out/nix-support/hydra-build-products
      echo "file bzip2 ${build}/on-server/bzip2" >> $out/nix-support/hydra-build-products
    '';
  };

  bootstrapFiles = {
    sh      = "${build}/on-server/sh";
    bzip2   = "${build}/on-server/bzip2";
    mkdir   = "${build}/on-server/mkdir";
    cpio    = "${build}/on-server/cpio";
    tarball = "${build}/on-server/bootstrap-tools.cpio.bz2";
  };

  unpack = stdenv.mkDerivation (bootstrapFiles // {
    name = "unpack";

    # This is by necessity a near-duplicate of unpack-bootstrap-tools.sh. If we refer to it directly,
    # we can't make any changes to it due to our testing stdenv depending on it. Think of this as the
    # unpack-bootstrap-tools.sh for the next round of bootstrap tools.
    # TODO: think through alternate designs, such as hosting this script as an output of the process.
    buildCommand = ''
      # Unpack the bootstrap tools tarball.
      echo Unpacking the bootstrap tools...
      $mkdir $out
      $bzip2 -d < $tarball | (cd $out && $cpio -i)

      # Set the ELF interpreter / RPATH in the bootstrap binaries.
      echo Patching the tools...

      export PATH=$out/bin

      for i in $out/bin/*; do
        if ! test -L $i; then
          echo patching $i
          install_name_tool -add_rpath $out/lib $i || true
        fi
      done

      for i in $out/lib/*.dylib; do
        if ! test -L $i; then
          echo patching $i

          id=$(otool -D "$i" | tail -n 1)
          install_name_tool -id "$(dirname $i)/$(basename $id)" $i

          libs=$(otool -L "$i" | tail -n +2 | grep -v libSystem | cat)
          if [ -n "$libs" ]; then
            install_name_tool -add_rpath $out/lib $i
          fi
        fi
      done

      ln -s bash $out/bin/sh
      ln -s bzip2 $out/bin/bunzip2

      # Provide a gunzip script.
      cat > $out/bin/gunzip <<EOF
      #!$out/bin/sh
      exec $out/bin/gzip -d "\$@"
      EOF
      chmod +x $out/bin/gunzip

      # Provide fgrep/egrep.
      echo "#! $out/bin/sh" > $out/bin/egrep
      echo "exec $out/bin/grep -E \"\$@\"" >> $out/bin/egrep
      echo "#! $out/bin/sh" > $out/bin/fgrep
      echo "exec $out/bin/grep -F \"\$@\"" >> $out/bin/fgrep

      cat >$out/bin/dsymutil << EOF
      #!$out/bin/sh
      EOF

      chmod +x $out/bin/egrep $out/bin/fgrep $out/bin/dsymutil
    '';

    allowedReferences = [ "out" ];
  });

  test = stdenv.mkDerivation {
    name = "test";

    realBuilder = "${unpack}/bin/bash";

    frameworks = [ "CoreFoundation" ];

    buildCommand = ''
      export PATH=${unpack}/bin
      ls -l
      mkdir $out
      mkdir $out/bin
      sed --version
      find --version
      diff --version
      patch --version
      make --version
      awk --version
      grep --version
      clang --version
      xz --version

      # The grep will return a nonzero exit code if there is no match, and we want to assert that we have
      # an SSL-capable curl
      curl --version | grep SSL

      ${build}/on-server/sh -c 'echo Hello World'

      export SDKROOT="${builtins.xcodeSDKRoot}"
      export flags="-L${unpack}/lib -isystem $SDKROOT/usr/include -L$SDKROOT/usr/lib -F$SDKROOT/System/Library/Frameworks"

      export CPP="clang -E $flags"
      export CC="clang $flags -Wl,-rpath,${unpack}/lib -Wl,-v"
      export CXX="clang++ $flags --stdlib=libc++ -lc++abi -isystem${unpack}/include/c++/v1 -Wl,-rpath,${unpack}/lib -Wl,-v"

      echo '#include <stdio.h>' >> foo.c
      echo '#include <float.h>' >> foo.c
      echo '#include <limits.h>' >> foo.c
      echo 'int main() { printf("Hello World\n"); return 0; }' >> foo.c
      $CC -o $out/bin/foo foo.c
      $out/bin/foo

      echo '#include <CoreFoundation/CoreFoundation.h>' >> bar.c
      echo 'int main() { CFShow(CFSTR("Hullo")); return 0; }' >> bar.c
      $CC -F${unpack}/Library/Frameworks -framework CoreFoundation -o $out/bin/bar bar.c
      $out/bin/bar

      echo '#include <iostream>' >> bar.cc
      echo 'int main() { std::cout << "Hello World\n"; }' >> bar.cc
      $CXX -v -o $out/bin/bar bar.cc
      $out/bin/bar

      tar xvf ${hello.src}
      cd hello-*
      ./configure --prefix=$out
      make
      make install

      $out/bin/hello
    '';
  };

  # The ultimate test: bootstrap a whole stdenv from the tools specified above and get a package set out of it
  test-pkgs = import test-pkgspath {
    inherit system;
    stdenvFunc = args: let
        args' = args // { inherit bootstrapFiles; };
      in (import (test-pkgspath + "/pkgs/stdenv/darwin") args').stdenvDarwin;
  };
}
