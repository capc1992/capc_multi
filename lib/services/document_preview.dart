import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../platform/platform_services.dart';

const _previewPdfType = DocumentType(
  label: 'Documento PDF',
  extensions: ['pdf'],
  mimeType: 'application/pdf',
);

/// A preview never prints as a side effect of opening or rebuilding the view.
Future<void> showCapcDocument(
  BuildContext context, {
  required String title,
  required Future<Uint8List> Function() build,
  bool ticket = false,
}) => showDialog<void>(
  context: context,
  builder: (_) => _DocumentDialog(title: title, build: build, ticket: ticket),
);

class _DocumentDialog extends StatefulWidget {
  const _DocumentDialog({
    required this.title,
    required this.build,
    required this.ticket,
  });
  final String title;
  final Future<Uint8List> Function() build;
  final bool ticket;

  @override
  State<_DocumentDialog> createState() => _DocumentDialogState();
}

class _DocumentDialogState extends State<_DocumentDialog> {
  late final Future<Uint8List> _document = widget.build();
  bool _busy = false;
  String? _message;

  PdfPageFormat get _format => widget.ticket
      ? const PdfPageFormat(80 * PdfPageFormat.mm, 250 * PdfPageFormat.mm)
      : PdfPageFormat.letter;

  Future<void> _action(_DocumentAction action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await _document;
      if (action == _DocumentAction.print) {
        final printed = await appPlatform.printPdf(
          bytes: bytes,
          name: widget.title,
          format: _format,
        );
        if (mounted) {
          setState(
            () => _message = printed
                ? 'Documento enviado mediante el diálogo de impresión. Comprueba la salida de papel antes de repetir.'
                : 'Impresión cancelada.',
          );
        }
      } else if (action == _DocumentAction.share) {
        final shared = await appPlatform.sharePdf(
          bytes: bytes,
          name:
              '${widget.title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-')}.pdf',
        );
        if (mounted) {
          setState(
            () => _message = shared
                ? 'Se abrió el panel para compartir el PDF.'
                : 'No se compartió el PDF.',
          );
        }
      } else {
        final saved = await appPlatform.saveDocument(
          buildBytes: () async => bytes,
          suggestedName:
              '${widget.title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-')}.pdf',
          type: _previewPdfType,
        );
        if (saved != null && mounted) {
          setState(() => _message = 'PDF guardado.');
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'No se pudo completar la operación: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 1000,
      height: MediaQuery.sizeOf(context).height * .9,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Cerrar vista previa',
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<Uint8List>(
              future: _document,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: SelectableText(
                        'No se pudo generar el PDF: ${snapshot.error}',
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return PdfPreview(
                  build: (_) async => snapshot.data!,
                  initialPageFormat: _format,
                  canChangeOrientation: false,
                  canChangePageFormat: false,
                  canDebug: false,
                  allowPrinting: false,
                  allowSharing: false,
                  useActions: false,
                  pdfFileName: '${widget.title}.pdf',
                );
              },
            ),
          ),
          if (_message != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_message!)),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _action(_DocumentAction.save),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Guardar PDF'),
                ),
                if (appPlatform.supportsDocumentSharing)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _action(_DocumentAction.share),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Compartir PDF'),
                  ),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _action(_DocumentAction.print),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Imprimir…'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

enum _DocumentAction { save, share, print }
