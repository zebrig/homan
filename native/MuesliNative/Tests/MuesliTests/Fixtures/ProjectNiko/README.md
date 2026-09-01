# Project Niko Jinja fixtures

- `embedded_template.jinja` is the chat template extracted from the locally installed
  `gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf` used to reproduce the original report.
- `google_current_template.jinja` is the Google Gemma 4 canonical template published on
  2026-07-09 and evaluated during the Project Niko architecture spike.
- `*.reference.txt` files are byte-for-byte outputs generated with Python Jinja2 3.1.6 for the
  fixed system/user fixture in `GemmaChatTemplateTests`, covering three language policies and
  thinking on/off.

These resources are deliberately bundled with the test target. Updating a model template must not
rewrite the reference outputs in the same change unless parity has first been independently checked
against Python Jinja2.
