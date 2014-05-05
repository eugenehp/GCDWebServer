#!/bin/bash -e

OSX_SDK="macosx"
if [ -z "$TRAVIS" ]; then
  IOS_SDK="iphoneos"
else
  IOS_SDK="iphonesimulator"
fi

OSX_TARGET="GCDWebServer (Mac)"
IOS_TARGET="GCDWebServer (iOS)"
CONFIGURATION="Release"

MRC_BUILD_DIR="/tmp/GCDWebServer-MRC"
MRC_PRODUCT="$MRC_BUILD_DIR/$CONFIGURATION/GCDWebServer"
ARC_BUILD_DIR="/tmp/GCDWebServer-ARC"
ARC_PRODUCT="$ARC_BUILD_DIR/$CONFIGURATION/GCDWebServer"

PAYLOAD_ZIP="Tests/Payload.zip"
PAYLOAD_DIR="/tmp/GCDWebServer"

TRACE_SCRIPT="/tmp/trace.d"
TRACE_OUTPUT="/tmp/trace.txt"
DTRACE_SCRIPT='

#!/usr/bin/env dtrace -s
#pragma D option quiet

pid$target:libobjc.A.dylib:class_createInstance:entry
{
  ptr0 = arg0;
  ptr1 = *(long*)copyin(ptr0, 8);
  ptr2 = *(long*)copyin((ptr1 + 32) & ~3, 8);
  flags = *(int*)copyin(ptr2, 4);
  ptr3 = (flags & (1 << 31)) || (flags & (1 << 30)) ? *(long*)copyin(ptr2 + 8, 8) : ptr2;
  ptr4 = *(long*)copyin(ptr3 + 24, 8);
  class = copyinstr(ptr4);
  
  @allocations[class] = sum(1);
}

/* Do not use objc_destructInstance() which is used to recycle objects */
pid$target:libobjc.A.dylib:object_dispose:entry
/arg0 != 0/
{
  ptr0 = *(long*)copyin(arg0, 8);  /* TODO: Getting ISA from object this way will not work for tagged pointers but they likely do not get disposed of anyway */
  ptr1 = *(long*)copyin(ptr0, 8);
  ptr2 = *(long*)copyin((ptr1 + 32) & ~3, 8);
  ptr3 = (flags & (1 << 31)) || (flags & (1 << 30)) ? *(long*)copyin(ptr2 + 8, 8) : ptr2;
  ptr4 = *(long*)copyin(ptr3 + 24, 8);
  class = copyinstr(ptr4);
  
  @allocations[class] = sum(-1);
}

END
{
  printa(@allocations);
}

'

function runTests {
  sudo rm -rf "$PAYLOAD_DIR"
  ditto -x -k "$PAYLOAD_ZIP" "$PAYLOAD_DIR"
  TZ=GMT find "$PAYLOAD_DIR" -type d -exec SetFile -d "1/1/2014 00:00:00" -m "1/1/2014 00:00:00" '{}' \;  # ZIP archives do not preserve directories dates
  if [ "$4" != "" ]; then
    cp -f "$4" "$PAYLOAD_DIR/Payload"
    pushd "$PAYLOAD_DIR/Payload"
    SetFile -d "1/1/2014 00:00:00" -m "1/1/2014 00:00:00" `basename "$4"`
    popd
  fi
  
  sudo rm -f "$TRACE_OUTPUT"
  sudo DYLD_SHARED_REGION=avoid logLevel=2 dtrace -s "$TRACE_SCRIPT" -o "$TRACE_OUTPUT" -c "$1 -mode $2 -root $PAYLOAD_DIR/Payload -tests $3"
  
  echo "=============== LIVE OBJ-C OBJECTS ==============="
  OLD_IFS="$IFS"
  IFS=$'\n'
  SUCCESS=1
  for LINE in `sort -b "$TRACE_OUTPUT"`; do
    CLASS=`echo -n "$LINE" | awk '{ print $1 }'`
    COUNT=`echo -n "$LINE" | awk '{ print $2 }'`
    if [[ "$CLASS" != OS_* && "$CLASS" != _NS*  && "$CLASS" != __NS* && "$CLASS" != __CF* ]]; then
      if [ $COUNT -gt 0 ]; then
        printf "%40s %7s\n" "$CLASS" "$COUNT"
        if [[ "$CLASS" == GCDWebServer* ]]; then
          SUCCESS=0
        fi
      fi
    fi
  done
  IFS="$OLD_IFS"
  echo "=================================================="
  if [ $SUCCESS -eq 0 ]; then
    echo "[FAILURE] GCDWebServer objects are leaking!"
    exit 1
  fi
  
  # logLevel=2 $1 -mode "$2" -root "$PAYLOAD_DIR/Payload" -tests "$3"
}

# Build for iOS in manual memory management mode (TODO: run tests on iOS)
rm -rf "$MRC_BUILD_DIR"
xcodebuild -sdk "$IOS_SDK" -target "$IOS_TARGET" -configuration "$CONFIGURATION" build "SYMROOT=$MRC_BUILD_DIR" "CLANG_ENABLE_OBJC_ARC=NO" > /dev/null

# Build for iOS in ARC mode (TODO: run tests on iOS)
rm -rf "$ARC_BUILD_DIR"
xcodebuild -sdk "$IOS_SDK" -target "$IOS_TARGET" -configuration "$CONFIGURATION" build "SYMROOT=$ARC_BUILD_DIR" "CLANG_ENABLE_OBJC_ARC=YES" > /dev/null

# Build for OS X in manual memory management mode
rm -rf "$MRC_BUILD_DIR"
xcodebuild -sdk "$OSX_SDK" -target "$OSX_TARGET" -configuration "$CONFIGURATION" build "SYMROOT=$MRC_BUILD_DIR" "CLANG_ENABLE_OBJC_ARC=NO" > /dev/null

# Build for OS X in ARC mode
rm -rf "$ARC_BUILD_DIR"
xcodebuild -sdk "$OSX_SDK" -target "$OSX_TARGET" -configuration "$CONFIGURATION" build "SYMROOT=$ARC_BUILD_DIR" "CLANG_ENABLE_OBJC_ARC=YES" > /dev/null

# Prepare tests
rm -f "$TRACE_SCRIPT"
echo "$DTRACE_SCRIPT" > "$TRACE_SCRIPT"

# Run tests
runTests $MRC_PRODUCT "htmlForm" "Tests/HTMLForm"
runTests $ARC_PRODUCT "htmlForm" "Tests/HTMLForm"
runTests $MRC_PRODUCT "htmlFileUpload" "Tests/HTMLFileUpload"
runTests $ARC_PRODUCT "htmlFileUpload" "Tests/HTMLFileUpload"
runTests $MRC_PRODUCT "webServer" "Tests/WebServer"
runTests $ARC_PRODUCT "webServer" "Tests/WebServer"
runTests $MRC_PRODUCT "webDAV" "Tests/WebDAV-Transmit"
runTests $ARC_PRODUCT "webDAV" "Tests/WebDAV-Transmit"
runTests $MRC_PRODUCT "webDAV" "Tests/WebDAV-Cyberduck"
runTests $ARC_PRODUCT "webDAV" "Tests/WebDAV-Cyberduck"
runTests $MRC_PRODUCT "webDAV" "Tests/WebDAV-Finder"
runTests $ARC_PRODUCT "webDAV" "Tests/WebDAV-Finder"
runTests $MRC_PRODUCT "webUploader" "Tests/WebUploader"
runTests $ARC_PRODUCT "webUploader" "Tests/WebUploader"
runTests $MRC_PRODUCT "webServer" "Tests/WebServer-Sample-Movie" "Tests/Sample-Movie.mp4"
runTests $ARC_PRODUCT "webServer" "Tests/WebServer-Sample-Movie" "Tests/Sample-Movie.mp4"

# Done
echo "\nAll tests completed successfully!"
