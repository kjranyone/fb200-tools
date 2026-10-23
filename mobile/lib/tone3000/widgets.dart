import '../localization.dart';

import 'package:flutter/material.dart';

import '../tone3000.dart';

class Tone3000Logo extends StatelessWidget {
  const Tone3000Logo({super.key});
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/tone3000.png',
    height: 32,
    alignment: Alignment.centerLeft,
    semanticLabel: 'TONE3000',
  );
}

class ToneImage extends StatelessWidget {
  final Uri? image;
  final double size;
  const ToneImage(this.image, {super.key, this.size = 64});
  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(
      width: size,
      height: size,
      child: const Icon(Icons.graphic_eq),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: image == null
          ? fallback
          : Image.network(
              image.toString(),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class ToneAttribution extends StatelessWidget {
  final TonePack tone;
  const ToneAttribution(this.tone, {super.key});
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (tone.image != null) ...[
        ToneImage(tone.image),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tone.title, style: Theme.of(context).textTheme.titleMedium),
            Text('${tone.gearLabel} · NAM A2'),
            Text(
              '@${tone.creator.username}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ],
  );
}

/// Centered, width-limited scrolling column used by both library tabs.
class ToneScroll extends StatelessWidget {
  final List<Widget> children;
  const ToneScroll(this.children, {super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        children: children,
      ),
    ),
  );
}

/// A listed tone with its stored count and a whole-tone download action.
class ToneTile extends StatelessWidget {
  final TonePack tone;

  /// Models of this tone already in the device library.
  final int stored;
  final bool enabled;
  final VoidCallback onOpen, onDownload;
  const ToneTile({
    super.key,
    required this.tone,
    required this.stored,
    required this.enabled,
    required this.onOpen,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final complete = tone.a2Count != null && stored >= tone.a2Count!;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ToneImage(tone.image, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tone.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      tone.a2Count == null
                          ? '${tone.gearLabel} · NAM A2'
                          : tr("{0} · NAM A2 · {1} モデル", [
                              tone.gearLabel,
                              tone.a2Count,
                            ]),
                    ),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 8,
                          backgroundImage: tone.creator.avatar == null
                              ? null
                              : NetworkImage(tone.creator.avatar.toString()),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '@${tone.creator.username}',
                            style: Theme.of(context).textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (stored > 0)
                      Text(
                        tr("端末に保存済み {0} 件", [stored]),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              complete
                  ? Tooltip(
                      message: tr("すべて端末に保存済み"),
                      child: const Icon(Icons.download_done),
                    )
                  : IconButton(
                      tooltip: tr("すべてダウンロード"),
                      onPressed: enabled ? onDownload : null,
                      icon: const Icon(Icons.download_outlined),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
