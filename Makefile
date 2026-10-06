ARCHS = arm64
TARGET = iphone:clang:latest:10.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PadDisplay
PadDisplay_FILES = src/main.m src/AppDelegate.m src/PDLog.m src/DisplayViewController.m src/Network/PDStreamReceiver.m src/Video/PDH264Parser.m src/Video/PDVideoDecoder.m
PadDisplay_CFLAGS = -fobjc-arc -Isrc -Isrc/Network -Isrc/Video
PadDisplay_FRAMEWORKS = UIKit Foundation AVFoundation VideoToolbox CoreMedia CoreVideo
PadDisplay_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache || true; killall -9 SpringBoard || true"
