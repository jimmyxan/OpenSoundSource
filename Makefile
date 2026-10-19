APP = OpenSoundSource.app

run: app
	open $(APP)

app:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/OpenSoundSource $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
