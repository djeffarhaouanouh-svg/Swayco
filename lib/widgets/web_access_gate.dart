import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Blocks the web build behind a simple access code before [child] mounts.
/// Web-only gate — native builds never see this. Not real security (the
/// code ships in the compiled JS), just a soft barrier so the public URL
/// isn't wide open before launch. Persisted in the browser's localStorage
/// so a returning visitor on the same browser isn't asked again.
class WebAccessGate extends StatefulWidget {
  const WebAccessGate({super.key, required this.child});

  final Widget child;

  static const _code = '1234';
  static const _prefsKey = 'web_access_unlocked';

  @override
  State<WebAccessGate> createState() => _WebAccessGateState();
}

class _WebAccessGateState extends State<WebAccessGate> {
  bool? _unlocked;
  final _controller = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkStored();
  }

  Future<void> _checkStored() async {
    bool unlocked = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      unlocked = prefs.getBool(WebAccessGate._prefsKey) ?? false;
    } catch (_) {}
    if (mounted) setState(() => _unlocked = unlocked);
  }

  Future<void> _submit() async {
    if (_controller.text.trim() != WebAccessGate._code) {
      setState(() => _error = 'Code incorrect');
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(WebAccessGate._prefsKey, true);
    } catch (_) {}
    if (mounted) setState(() => _unlocked = true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked == null) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    if (_unlocked == true) return widget.child;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Accès restreint',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Code d’accès',
                      hintStyle: const TextStyle(color: Colors.white54),
                      errorText: _error,
                      enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white),
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _submit,
                      child: const Text('Valider'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
