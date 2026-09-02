import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import 'ai_ui_support.dart';

/// Schema fragments shared by the Pointy catalog items.
///
/// Note what is absent and stays absent: colour, size, padding, font, width,
/// radius, elevation. The model composes; the widgets style. A lint test
/// asserts none of those names ever appear in a catalog schema.
abstract final class AiSchemas {
  /// A semantic tone.
  static Schema tone({String? description}) => S.string(
    description:
        description ??
        'What the item means, which decides its colour. Never a colour name.',
    enumValues: aiToneNames,
  );

  /// How a value should be formatted by the client.
  static Schema valueKind({String? description}) => S.string(
    description:
        description ??
        'How to format the value. Use "money" for any amount in shop currency.',
    enumValues: aiValueKinds,
  );

  /// A tap target.
  ///
  /// The event name carries its own routing prefix:
  /// `navigate:` opens a screen in the app, `ask:` sends a follow-up question
  /// to the assistant, `submit:` sends the surface's collected data back.
  static Schema action({String? description}) => S.object(
    description:
        description ??
        'What happens on tap. The event name must start with "navigate:" to '
            'open a screen, "ask:" to ask the assistant a follow-up, or '
            '"submit:" to send this surface\'s inputs back.',
    properties: {
      'event': S.object(
        properties: {
          'name': S.string(
            description:
                'Prefixed action name, e.g. "navigate:open", "ask:breakdown", '
                '"submit:confirm".',
          ),
          'context': S.object(
            description:
                'Extra values sent with the action. For "navigate:" put the '
                'deep link in "link" (e.g. "pointy://product/12"). For "ask:" '
                'put the follow-up question in "prompt".',
          ),
        },
        required: ['name'],
      ),
    },
    required: ['event'],
  );

  /// A row of a table or a list of records, either inline or bound to a path.
  static Schema records({required Schema item, String? description}) =>
      A2uiSchemas.listOrReference(items: item, description: description);
}
