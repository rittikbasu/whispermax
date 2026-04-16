#!/bin/bash
# Reset permissions + onboarding state, then launch the debug build.
# Run this after each rebuild to test onboarding cleanly.
pkill -f "whispermax" 2>/dev/null
sleep 0.3
tccutil reset Accessibility com.whispermax.app 2>/dev/null
rm -f ~/Library/Application\ Support/WhisperMax/onboarding-complete
open ~/Library/Developer/Xcode/DerivedData/WhisperMax-*/Build/Products/Debug/whispermax.app
