import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

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

  Future<void> _action(bool print) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await _document;
      if (print) {
        final printed = await Printing.layoutPdf(
          name: widget.title,
          format: _format,
          dynamicLayout: false,
          windowsModernDialog: true,
          onLayout: (_) async => bytes,
        );
        if (mounted) {
          setState(
            () => _message = printed
                ? 'Documento enviado mediante el diálogo de Windows. Comprueba la salida de papel antes de repetir.'
                : 'Impresión cancelada.',
          );
        }
      } else {
        final destination = await getSaveLocation(
          suggestedName:
              '${widget.title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-')}.pdf',
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Documento PDF', extensions: ['pdf']),
          ],
          confirmButtonText: 'Guardar PDF',
        );
        if (destination != null) {
          await XFile.fromData(
            bytes,
            mimeType: 'application/pdf',
          ).saveTo(destination.path);
          if (mounted) setState(() => _message = 'PDF guardado.');
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
                  onPressed: _busy ? null : () => _action(false),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Guardar PDF'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _action(true),
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
