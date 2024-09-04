// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import '../type_helper.dart';
import 'decode_helper.dart';
import 'encoder_helper.dart';
import 'field_helpers.dart';
import 'helper_core.dart';
import 'settings.dart';
import 'utils.dart';

class GeneratorHelper extends HelperCore with EncodeHelper, DecodeHelper {
  final Settings _generator;
  final _addedMembers = <String>{};

  GeneratorHelper(
    this._generator,
    ClassElement element,
    ConstantReader annotation,
  ) : super(
            element,
            mergeConfig(
              _generator.config,
              annotation,
              classElement: element,
            ));

  @override
  void addMember(String memberContent) {
    _addedMembers.add(memberContent);
  }

  @override
  Iterable<TypeHelper> get allTypeHelpers => _generator.allHelpers;

  Iterable<String> generate() sync* {
    assert(_addedMembers.isEmpty);

    if (config.genericArgumentFactories && element.typeParameters.isEmpty) {
      log.warning(
        'The class `${element.displayName}` is annotated '
        'with `JsonSerializable` field `genericArgumentFactories: true`. '
        '`genericArgumentFactories: true` only affects classes with type '
        'parameters. For classes without type parameters, the option is '
        'ignored.',
      );
    }
    // print('All Helpers: ${_generator.allHelpers..forEach((element) {element.toString();})}');
    final sortedFields = createSortedFieldSet(element);

    // Used to keep track of why a field is ignored. Useful for providing
    // helpful errors when generating constructor calls that try to use one of
    // these fields.
    final unavailableReasons = <String, String>{};

    final accessibleFields = sortedFields.fold<Map<String, FieldElement>>(
      <String, FieldElement>{},
      (map, field) {
        final jsonKey = jsonKeyFor(field);
        if (!field.isPublic && !jsonKey.explicitYesFromJson) {
          unavailableReasons[field.name] = 'It is assigned to a private field.';
        } else if (field.getter == null) {
          assert(field.setter != null);
          unavailableReasons[field.name] =
              'Setter-only properties are not supported.';
          log.warning('Setters are ignored: ${element.name}.${field.name}');
        } else if (jsonKey.explicitNoFromJson) {
          unavailableReasons[field.name] =
              'It is assigned to a field not meant to be used in fromJson.';
        } else {
          assert(!map.containsKey(field.name));
          map[field.name] = field;
        }

        return map;
      },
    );
    // print("Accessible fields: ${accessibleFields.toString()}");
    var accessibleFieldSet = accessibleFields.values.toSet();
    if (config.createFactory) {
      final createResult = createFactory(accessibleFields, unavailableReasons);
      // print("create Result: ${createResult.output}");
      yield createResult.output;

      final fieldsToUse = accessibleFields.entries
          .where((e) => createResult.usedFields.contains(e.key))
          .map((e) => e.value)
          .toList();

      // Need to add candidates BACK even if they are not used in the factory if
      // they are forced to be used for toJSON
      for (var candidate in sortedFields.where((element) =>
          jsonKeyFor(element).explicitYesToJson &&
          !fieldsToUse.contains(element))) {
        fieldsToUse.add(candidate);
      }

      // Need the fields to maintain the original source ordering
      fieldsToUse.sort(
          (a, b) => sortedFields.indexOf(a).compareTo(sortedFields.indexOf(b)));

      accessibleFieldSet = fieldsToUse.toSet();
    }

    accessibleFieldSet
      ..removeWhere(
        (element) => jsonKeyFor(element).explicitNoToJson,
      )

      // Check for duplicate JSON keys due to colliding annotations.
      // We do this now, since we have a final field list after any pruning done
      // by `_writeCtor`.
      ..fold(
        <String>{},
        (Set<String> set, fe) {
          final jsonKey = nameAccess(fe);
          if (!set.add(jsonKey)) {
            throw InvalidGenerationSourceError(
              'More than one field has the JSON key for name "$jsonKey".',
              element: fe,
            );
          }
          return set;
        },
      );

    print("Accessible field set: ${accessibleFieldSet}");

    if (config.createFieldMap) {
      print("Field Map: ${createFieldMap(accessibleFieldSet)}");
      yield createFieldMap(accessibleFieldSet);
    }

    if (config.createJsonKeys) {
      print("Json Keys: ${createJsonKeys(accessibleFieldSet)}");
      yield createJsonKeys(accessibleFieldSet);
    }

    if (config.createPerFieldToJson) {
      print("Per field to Json: ${createPerFieldToJson(accessibleFieldSet)}");
      yield createPerFieldToJson(accessibleFieldSet);
    }

    if (config.createToJson) {
      print("To Json: ${createToJson(accessibleFieldSet)}");
      yield* createToJson(accessibleFieldSet);
    }

    yield* _addedMembers;
  }
}

extension on KeyConfig {
  bool get explicitYesFromJson => includeFromJson == true;

  bool get explicitNoFromJson => includeFromJson == false;

  bool get explicitYesToJson => includeToJson == true;

  bool get explicitNoToJson => includeToJson == false;
}
