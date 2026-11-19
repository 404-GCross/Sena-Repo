import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/settings_provider.dart";
import "../utils/theme_utils.dart";

class ServerAddressText extends StatelessWidget {
  const ServerAddressText(this.address, {super.key, this.style});

  final String address;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final hidden = context.select((SettingsProvider s) => s.hideServerAddress);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(hidden ? "********" : address, style: style)),
        const SizedBox(width: 2),
        IconButton(
          tooltip: hidden ? "显示服务器地址" : "隐藏服务器地址",
          icon: Icon(
            hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 16,
          ),
          color: hintColor(context),
          visualDensity: VisualDensity.compact,
          onPressed: () => context.read<SettingsProvider>().setHideServerAddress(!hidden),
        ),
      ],
    );
  }
}
