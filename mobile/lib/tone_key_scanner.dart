import 'localization.dart';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import 'tone3000.dart';

class ToneKeyScanner extends StatefulWidget {
  const ToneKeyScanner({super.key});

  @override
  State<ToneKeyScanner> createState() => _ToneKeyScannerState();
}

class _ToneKeyScannerState extends State<ToneKeyScanner> {
  bool _finished = false;
  String _error = '';

  void _detect(BarcodeCapture capture) {
    if (_finished || !mounted) return;
    String? error;
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode || barcode.rawValue == null) {
        continue;
      }
      try {
        final key = parsePublishableKeyQr(barcode.rawValue!);
        _finished = true;
        Navigator.pop(context, key);
        return;
      } on ToneError catch (e) {
        error = e.message;
      }
    }
    if (error != null && error != _error) {
      setState(() => _error = error!);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr("Publishable Keyを読み取る"))),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            // The widget owns its controller and handles camera lifecycle and
            // disposal. Images and decoded contents are never logged or sent.
            child: MobileScanner(
              onDetect: _detect,
              tapToFocus: true,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.no_photography_outlined, size: 48),
                      const SizedBox(height: 16),
                      Text(
                        error.errorCode ==
                                MobileScannerErrorCode.permissionDenied
                            ? tr("カメラの利用を許可してください。端末の設定で許可した後、読み取りを開き直せます。")
                            : tr("カメラを起動できませんでした。読み取りを開き直すか、手入力してください。"),
                      ),
                      if (error.errorCode ==
                          MobileScannerErrorCode.permissionDenied)
                        TextButton(
                          onPressed: openAppSettings,
                          child: Text(tr("端末の設定を開く")),
                        ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(tr("手入力に戻る")),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr("Publishable Keyの文字列を入れたQRコードにカメラを向けてください。")),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
