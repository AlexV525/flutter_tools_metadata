// Copyright 2020 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;

import '../common.dart';

Future<void> main(List<String> args) async {
  if (path.basename(Directory.current.path) != 'tools_metadata') {
    fail('Please run this tool from the root of the repo.');
  }

  final String flutterPackagePath =
      path.absolute(path.join(flutterSdkPath, 'packages/flutter/lib'));

  print('Setting up an analysis context...');

  final List<String> includedPaths = <String>[flutterPackagePath];
  final AnalysisContextCollection collection =
      AnalysisContextCollection(includedPaths: includedPaths);

  if (collection.contexts.length != 1) {
    fail('Expected one analysis context, found ${collection.contexts.length}.');
  }

  final AnalysisContext context = collection.contexts.first;
  final AnalysisSession session = context.currentSession;

  final List<String> files = context.contextRoot.analyzedFiles().toList();

  print('Scanning Dart files...');
  final List<String> libraryFiles = <String>[];
  for (final String file in files) {
    final FileResult fileResult = session.getFile(file) as FileResult;
    if (!fileResult.isPart) {
      libraryFiles.add(file);
    }
  }
  print('  ${libraryFiles.length} dart files');

  print("Resolving class 'Widget'...");

  final LibraryElementResult widgetsLibraryResult = await session
          .getLibraryByUri('package:flutter/src/widgets/framework.dart')
      as LibraryElementResult;
  final LibraryElement widgetsLibrary = widgetsLibraryResult.element;

  final ClassElement widgetClass =
      widgetsLibrary.getType('Widget') as ClassElement;

  print('Resolving widget subclasses...');
  final List<ClassElement> classes = <ClassElement>[];
  for (final String file in libraryFiles) {
    final ResolvedLibraryResult resolvedLibraryResult =
        await session.getResolvedLibrary(file) as ResolvedLibraryResult;

    final LibraryElement lib = resolvedLibraryResult.element;
    for (final Element element in lib.topLevelElements) {
      if (element is! ClassElement || element.isMixin) {
        continue;
      }

      final ClassElement clazz = element;
      if (clazz.allSupertypes.contains(widgetClass.thisType)) {
        // Hide private classes.
        final String name = clazz.name;
        if (!name.startsWith('_')) {
          classes.add(clazz);
        }
      }
    }
  }
  print('  ${classes.length} widgets');

  // Normalize the output json.
  classes.sort((ClassElement a, ClassElement b) => a.name.compareTo(b.name));

  final File file = File('resources/catalog/widgets.json');
  print('Generating ${path.relative(path.absolute(file.path))}...');
  final List<Map<String, Object>> widgets = <Map<String, Object>>[];
  for (final ClassElement c in classes) {
    widgets.add(_convertToJson(c, widgetClass));
  }

  final Map<String, String> versionInfo = calculateFlutterVersion();

  final Map<String, dynamic> json = <String, dynamic>{
    'flutter': <String, dynamic>{
      'version': versionInfo['frameworkVersion'],
      'channel': versionInfo['channel'],
    },
    'widgets': widgets,
  };

  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  final String output = encoder.convert(json);
  file.writeAsStringSync('$output\n');
  final int kb = (file.lengthSync() + 1023) ~/ 1024;
  print('  ${kb}kb');
}

Map<String, Object> _convertToJson(
  ClassElement classElement,
  ClassElement widgetClass,
) {
  // flutter/src/material/about.dart
  final String filePath = classElement.library.librarySource.uri.path;
  final String libraryName = filePath.split('/')[2];

  String? summary;
  final ElementAnnotation? summaryAnnotation =
      _getAnnotations(classElement, 'Summary').firstOrNull;
  if (summaryAnnotation != null) {
    final DartObject text =
        summaryAnnotation.computeConstantValue()!.getField('text')!;
    summary = text.toStringValue()!.trim();
  }

  List<String>? categories;
  final ElementAnnotation? categoryAnnotation =
      _getAnnotations(classElement, 'Category').firstOrNull;
  if (categoryAnnotation != null) {
    final DartObject value =
        categoryAnnotation.computeConstantValue()!.getField('sections')!;
    categories = value
        .toListValue()!
        .map((DartObject obj) => obj.toStringValue()!)
        .toList();
  }

  final Map<String, Object> m = <String, Object>{};
  m['name'] = classElement.name;
  if (classElement != widgetClass) {
    m['parent'] = classElement.supertype!.element.name;
  }
  m['library'] = libraryName;
  if (classElement.isAbstract) {
    m['abstract'] = true;
  }
  if (categories != null) {
    m['categories'] = categories;
  }
  m['description'] = summary ?? _singleLine(classElement.documentationComment);

  return m;
}

List<ElementAnnotation> _getAnnotations(ClassElement c, String name) {
  return c.metadata.where((ElementAnnotation a) {
    if (a.element is ConstructorElement) {
      return a.element?.enclosingElement?.name == name;
    } else {
      return false;
    }
  }).toList();
}

String _singleLine(String? docs) {
  if (docs == null) {
    return '';
  }

  return docs
      .split('\n')
      .map((String line) {
        return line.startsWith('/// ')
            ? line.substring(4)
            : line == '///'
                ? ''
                : line;
      })
      .map((String line) => line.trimRight())
      .takeWhile((String line) => line.isNotEmpty)
      .join(' ');
}

void fail(String message) {
  print(message);
  exit(1);
}
