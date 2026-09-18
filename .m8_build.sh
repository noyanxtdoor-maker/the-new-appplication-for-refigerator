#!/usr/bin/env bash
cd "C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911"
export PATH="/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin:$PATH"
export JAVA_HOME="C://Users//sherl//AppData//Local//NextTransferFlutter//jdk21//jdk-21.0.12.1+1"
export HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy=
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin/flutter.bat build apk --debug --no-pub > .m8_build.out 2>&1
echo "BUILD_EXIT=$?" >> .m8_build.out
