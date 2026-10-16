CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -pedantic -O2
CPPFLAGS ?= -Icore/include
IOS_SDK ?= iphoneos
IOS_ARCH ?= arm64
IOS_MIN_VERSION ?= 15.0

.PHONY: test shared ios-dylib clean

test: build/test_snapshot
	./build/test_snapshot

shared: build/libcl_snapshot.so

build/libcl_snapshot.so: core/src/CLSnapshot.c core/include/CLSnapshot.h
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC -shared core/src/CLSnapshot.c -lm -o $@

ios-dylib: core/src/CLSnapshot.c core/include/CLSnapshot.h
	mkdir -p build
	xcrun --sdk $(IOS_SDK) clang $(CPPFLAGS) -std=c11 -Wall -Wextra -Werror -O2 \
		-arch $(IOS_ARCH) -miphoneos-version-min=$(IOS_MIN_VERSION) \
		-dynamiclib core/src/CLSnapshot.c -o build/libcl_snapshot.dylib \
		-install_name @rpath/libcl_snapshot.dylib

build/test_snapshot: core/src/CLSnapshot.c tests/test_snapshot.c core/include/CLSnapshot.h
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) core/src/CLSnapshot.c tests/test_snapshot.c -lm -o $@

clean:
	rm -rf build
