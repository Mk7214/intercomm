import 'package:flutter/material.dart';

class DialAction {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const DialAction({required this.icon, required this.label, this.onPressed});
}

/// Floating "speed dial": one main button; tapping it fans [actions] out
/// upwards with labels. Tapping an action or the main button again collapses it.
/// Place it in a bottom-right Positioned — it grows upwards from there.
class ActionDial extends StatefulWidget {
  final List<DialAction> actions;

  const ActionDial({super.key, required this.actions});

  @override
  State<ActionDial> createState() => _ActionDialState();
}

class _ActionDialState extends State<ActionDial> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  bool _open = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    _open ? _controller.forward() : _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.actions.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Listed top-to-bottom; the action nearest the main button animates first.
        for (var i = 0; i < count; i++)
          _buildAction(widget.actions[i], staggerIndex: count - 1 - i, count: count),
        FloatingActionButton(
          heroTag: null,
          tooltip: _open ? 'Close' : 'Menu',
          onPressed: _toggle,
          child: RotationTransition(
            turns: Tween(begin: 0.0, end: 0.125).animate(_controller), // + -> x
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _buildAction(DialAction action, {required int staggerIndex, required int count}) {
    // Each action starts a little after the one below it.
    final begin = staggerIndex / (count * 2);
    final animation = CurvedAnimation(
      parent: _controller,
      curve: Interval(begin, (begin + 0.5).clamp(0.0, 1.0), curve: Curves.easeOut),
    );
    final scheme = Theme.of(context).colorScheme;

    return SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.bottomRight, // grow upwards from the bottom
      child: FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: animation,
          alignment: Alignment.centerRight,
          child: Padding(
            // Small FAB (40) centred over the main FAB (56).
            padding: const EdgeInsets.only(bottom: 12, right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  color: scheme.surface,
                  elevation: 2,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(action.label),
                  ),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.small(
                  heroTag: null,
                  tooltip: action.label,
                  onPressed: action.onPressed == null
                      ? null
                      : () {
                          _toggle();
                          action.onPressed!();
                        },
                  child: Icon(action.icon),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
