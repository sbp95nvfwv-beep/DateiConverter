# DateiConverter for macOS

Eine native macOS-App. Sie konvertiert Dateien lokal auf dem Mac; die Dateien werden nicht hochgeladen.

## Unterstützte Umwandlungen

- Bilder: JPG, PNG, TIFF, BMP und GIF (GIF-Ausgabe enthält das erste Bild)
- Audio: M4A, WAV, AIFF und CAF; M4A-Ausgabe hängt vom Quellformat ab
- Video: MP4, MOV und M4V (Apple AVFoundation)
- Dokumente: TXT, RTF, HTML und PDF; Text aus PDF-Dateien kann extrahiert werden
- Eingaben: TXT, RTF, RTFD, HTML, DOC, DOCX, ODT und PDF

## Bauen

```sh
swift build -c release
```

GitHub Actions baut bei jedem Push eine universelle macOS-App für Apple Silicon und Intel. Bei einem Versions-Tag wird die App als dauerhaftes ZIP in einer GitHub-Release veröffentlicht.
