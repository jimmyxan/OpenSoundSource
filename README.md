# OpenSoundSource

[Italiano](#italiano) | [English](#english)

---

## Italiano

OpenSoundSource è un'app per la barra dei menu di macOS che controlla l'audio per singola app e per dispositivo. È un progetto indipendente, scritto da zero con le API pubbliche di Apple. Non è affiliato a Rogue Amoeba e non contiene codice, asset o dati di SoundSource.

### Funzioni

- Volume per app da 0 a 150%, con mute e aggancio magnetico a 100%.
- Limitatore soft-knee: sopra 100% l'audio non va in clipping.
- Funziona anche con le app che suonano da processi helper (Microsoft Teams, browser, app Electron).
- Elenco delle sole app che stanno emettendo suono (filtro attivabile).
- Dispositivi di uscita e ingresso: scelta del dispositivo predefinito, volume, mute e bilanciamento.
- Bluetooth: connessione e disconnessione delle periferiche audio già accoppiate.
- I volumi per app seguono il cambio del dispositivo predefinito (per esempio quando metti le AirPods).
- Avvio al login.
- Consumo a riposo praticamente nullo: nessun polling con il popover chiuso e nessun tap attivo.

### Requisiti

- macOS 14.2 o successivo (servono i process tap di CoreAudio).
- Mac con Apple Silicon o Intel.
- Strumenti da riga di comando di Xcode, con Swift 5.9 o successivo.

### Installazione e avvio, passo per passo

1. Installa gli strumenti da riga di comando, se non li hai:

   ```bash
   xcode-select --install
   ```

2. Clona il repository:

   ```bash
   git clone https://github.com/<tuo-utente>/OpenSoundSource.git
   cd OpenSoundSource
   ```

3. Compila e avvia l'app:

   ```bash
   make run
   ```

   Il comando compila in modalità release, crea `OpenSoundSource.app`, la firma in locale (ad-hoc) e la apre.

4. Concedi i permessi quando macOS li chiede:
   - **Registrazione audio di sistema** (Privacy e sicurezza): serve per controllare il volume delle app. Senza questo permesso lo slider non ha effetto e l'app mostra un avviso con il pulsante per aprire le impostazioni.
   - **Bluetooth**: serve solo per connettere e disconnettere le periferiche dalla scheda Devices.

5. Clicca l'icona con i tre cursori nella barra dei menu in alto a destra.

Se l'icona non compare, la barra dei menu potrebbe essere piena: chiudi qualche icona o usa un gestore della barra.

Per installare l'app in modo stabile, copiala in Applicazioni:

```bash
cp -R OpenSoundSource.app /Applications/
```

L'opzione "Launch at login" funziona meglio con l'app in `/Applications`. Se macOS chiede un'approvazione, trovi l'interruttore in Impostazioni di Sistema, Generali, Elementi login.

### Come si usa

- **Scheda Apps**: trascina lo slider di un'app per cambiarne il volume. Clicca la percentuale per tornare a 100%. Il pulsante a destra attiva il mute. Oltre 100% lo slider diventa arancione (boost).
- **Scheda Devices**: clicca un dispositivo per renderlo predefinito. Sotto trovi volume, mute e bilanciamento del dispositivo selezionato.
- **Menu `…`**: avvio al login, filtro "Only apps playing audio", azzera tutti i volumi, esci.

### Sviluppo

```bash
swift build -c release                      # solo compilazione
make app                                    # compila e crea il bundle .app
.build/debug/OpenSoundSource --selftest     # controllo del limitatore (dopo swift build)
.build/release/OpenSoundSource --snapshot . # salva apps.png e devices.png del popover
```

Struttura:

- `Sources/OpenSoundSource/main.swift`: tap per app, limitatore, modello e delegate.
- `Sources/OpenSoundSource/Devices.swift`: dispositivi CoreAudio, Bluetooth, avvio al login.
- `Sources/OpenSoundSource/Views.swift`: interfaccia SwiftUI.

### Limiti noti

- Il tap presuppone audio stereo float32 interleaved. Dispositivi multicanale o con formati insoliti possono suonare male.
- L'audio con volume modificato esce sul dispositivo predefinito di sistema, non su un dispositivo scelto per singola app.
- AirPlay: un dispositivo già connesso si controlla come gli altri, ma scoprire e collegare nuovi ricevitori richiede API private. Usa le impostazioni Suono di macOS.
- Il limitatore è un waveshaper senza inviluppo: con boost forte può aggiungere una leggera saturazione.
- I volumi non vengono ricordati tra un avvio e l'altro.
- Firma ad-hoc, nessuna notarizzazione: su altri Mac Gatekeeper può chiedere conferma.
- Manca un test automatico oltre al controllo del limitatore. Il resto è stato verificato solo a mano.

### Note legali

Il nome SoundSource appartiene a Rogue Amoeba Software. Questo progetto è un'implementazione indipendente delle idee generali (volume per app) con API pubbliche e non intende imitarne marchio, grafica o codice.

---

## English

OpenSoundSource is a macOS menu bar app that controls audio per app and per device. It is an independent project written from scratch with Apple's public APIs. It is not affiliated with Rogue Amoeba and contains no SoundSource code, assets or data.

### Features

- Per-app volume from 0 to 150%, with mute and a magnetic snap at 100%.
- Soft-knee limiter: boosted audio above 100% does not clip.
- Works with apps that play audio from helper processes (Microsoft Teams, browsers, Electron apps).
- List of only the apps that are making sound right now (switchable filter).
- Output and input devices: choose the default device, volume, mute and balance.
- Bluetooth: connect and disconnect already paired audio devices.
- Per-app volumes follow the default device when it changes (for example when you put on AirPods).
- Launch at login.
- Near-zero idle cost: no polling while the popover is closed and no tap is active.

### Requirements

- macOS 14.2 or later (CoreAudio process taps are required).
- Apple Silicon or Intel Mac.
- Xcode command line tools, with Swift 5.9 or later.

### Install and run, step by step

1. Install the command line tools if you do not have them:

   ```bash
   xcode-select --install
   ```

2. Clone the repository:

   ```bash
   git clone https://github.com/<your-user>/OpenSoundSource.git
   cd OpenSoundSource
   ```

3. Build and launch the app:

   ```bash
   make run
   ```

   This builds in release mode, creates `OpenSoundSource.app`, signs it locally (ad-hoc) and opens it.

4. Grant the permissions when macOS asks:
   - **System audio recording** (Privacy & Security): needed to control app volume. Without it the sliders do nothing, and the app shows a warning with a button that opens the settings.
   - **Bluetooth**: only needed to connect and disconnect devices from the Devices tab.

5. Click the three-sliders icon in the menu bar at the top right.

If the icon does not show up, your menu bar may be full: quit a few menu bar apps or use a menu bar manager.

To install the app permanently, copy it to Applications:

```bash
cp -R OpenSoundSource.app /Applications/
```

"Launch at login" works best with the app in `/Applications`. If macOS asks for approval, the switch is in System Settings, General, Login Items.

### Usage

- **Apps tab**: drag an app's slider to change its volume. Click the percentage to reset to 100%. The button on the right toggles mute. Above 100% the slider turns orange (boost).
- **Devices tab**: click a device to make it the default. Volume, mute and balance of the selected device are shown below it.
- **`…` menu**: launch at login, the "Only apps playing audio" filter, reset all volumes, quit.

### Development

```bash
swift build -c release                      # build only
make app                                    # build and create the .app bundle
.build/debug/OpenSoundSource --selftest     # limiter check (after swift build)
.build/release/OpenSoundSource --snapshot . # save apps.png and devices.png of the popover
```

Layout:

- `Sources/OpenSoundSource/main.swift`: per-app taps, limiter, model and app delegate.
- `Sources/OpenSoundSource/Devices.swift`: CoreAudio devices, Bluetooth, launch at login.
- `Sources/OpenSoundSource/Views.swift`: SwiftUI interface.

### Known limitations

- The tap assumes stereo interleaved float32 audio. Multichannel devices or unusual formats may sound wrong.
- Audio with a changed volume plays on the system default device, not on a device chosen per app.
- AirPlay: an already connected device is controlled like any other, but discovering and connecting new receivers needs private APIs. Use macOS Sound settings for that.
- The limiter is an envelope-free waveshaper: with heavy boost it can add mild saturation.
- Volumes are not remembered between launches.
- Ad-hoc signed and not notarized: on other Macs Gatekeeper may ask for confirmation.
- There is no automated test beyond the limiter check. Everything else was verified by hand.

### Legal note

The name SoundSource belongs to Rogue Amoeba Software. This project is an independent implementation of general ideas (per-app volume) using public APIs and does not intend to imitate their trademark, artwork or code.
