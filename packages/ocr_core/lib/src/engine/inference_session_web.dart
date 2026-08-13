// import 'dart:js_interop';
// import 'dart:js_interop_unsafe';
// import 'dart:typed_data';

// import 'inference_session.dart';

// @JS('ort.InferenceSession')
// extension type _SessionJS._(JSObject _) implements JSObject {
//   external static JSPromise<_SessionJS> create(JSString modelUrl);
//   external JSPromise<JSObject> run(JSObject feeds);
//   external JSArray<JSString> get inputNames;
// }

// @JS('ort.Tensor')
// extension type _TensorJS._(JSObject _) implements JSObject {
//   external factory _TensorJS(
//     JSString type,
//     JSFloat32Array data,
//     JSArray<JSNumber> dims,
//   );
//   external JSFloat32Array get data;
//   external JSArray<JSNumber> get dims;
// }

// /// Wrapper JS interop ke `onnxruntime-web` (dimuat via <script> di
// /// web/index.html). Dipanggil dari Flutter Web lewat dart:js_interop —
// /// lihat README ocr_core untuk setup <script> tag yang dibutuhkan.
// ///
// /// CATATAN: signature exact `ort.InferenceSession`/`ort.Tensor` di atas
// /// perlu divalidasi lagi terhadap versi onnxruntime-web yang benar-benar
// /// dipakai (typings JS berubah antar versi) — perlakukan sebagai starting
// /// point, bukan final, sebelum dipakai production.
// class InferenceSessionImpl implements InferenceSession {
//   _SessionJS? _session;

//   @override
//   Future<void> load(String modelPath) async {
//     _session = await _SessionJS.create(modelPath.toJS).toDart;
//   }

//   @override
//   Future<TensorOutput> run(TensorInput input) async {
//     final session = _session;
//     if (session == null) {
//       throw StateError('InferenceSession belum di-load(). Panggil load() dulu.');
//     }

//     final dims = input.shape.map((e) => e.toJS).toList().toJS;
//     final tensor = _TensorJS('float32'.toJS, input.data.toJS, dims);

//     final inputName = session.inputNames.toDart.first.toDart;
//     final feeds = {inputName: tensor}.jsify() as JSObject;

//     final result = await session.run(feeds).toDart;
//     // Nama output tensor ditentukan oleh model ONNX itu sendiri (bukan
//     // input name) — ambil key pertama dari hasil run() secara dinamis.
//     final outputName = result.keys.first;
//     // final outputName = session.outputNames.toDart.first.toDart; // asumsi model punya 1 output saja

//     final outputTensor = result.getProperty(outputName.toJS) as _TensorJS;

//     return TensorOutput(
//       data: outputTensor.data.toDart,
//       shape: outputTensor.dims.toDart.map((e) => e.toDartInt).toList(),
//     );
//   }

//   @override
//   Future<void> dispose() async {
//     // ort.InferenceSession di Web tidak punya explicit dispose/release
//     // yang wajib dipanggil — GC browser yang menangani.
//     _session = null;
//   }
// }
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'inference_session.dart';

@JS('ort.InferenceSession')
extension type _SessionJS._(JSObject _) implements JSObject {
  external static JSPromise<_SessionJS> create(JSString modelUrl);

  external JSPromise<JSObject> run(JSObject feeds);

  external JSArray<JSString> get inputNames;

  external JSArray<JSString> get outputNames;

  external JSPromise<JSAny?> release();
}

@JS('ort.Tensor')
extension type _TensorJS._(JSObject _) implements JSObject {
  external factory _TensorJS(
    JSString type,
    JSFloat32Array data,
    JSArray<JSNumber> dims,
  );

  external JSFloat32Array get data;

  external JSArray<JSNumber> get dims;
}

/// Web implementation of [InferenceSession].
///
/// Uses `onnxruntime-web` exposed globally as:
///
/// ```html
/// <script src="onnxruntime-web/dist/ort.min.js"></script>
/// ```
///
/// The JavaScript global must be available as:
///
/// ```javascript
/// window.ort
/// ```
class InferenceSessionImpl implements InferenceSession {
  _SessionJS? _session;

  @override
  Future<void> load(String modelPath) async {
    if (modelPath.trim().isEmpty) {
      throw ArgumentError.value(
        modelPath,
        'modelPath',
        'Model path tidak boleh kosong.',
      );
    }

    // Release previous session if load() is called again.
    final previousSession = _session;

    if (previousSession != null) {
      try {
        await previousSession.release().toDart;
      } catch (_) {
        // Ignore release error when replacing the session.
      }

      _session = null;
    }

    _session = await _SessionJS
        .create(modelPath.toJS)
        .toDart;
  }

  @override
  Future<TensorOutput> run(TensorInput input) async {
    final session = _session;

    if (session == null) {
      throw StateError(
        'InferenceSession belum di-load(). '
        'Panggil load() terlebih dahulu.',
      );
    }

    if (input.shape.isEmpty) {
      throw ArgumentError(
        'Tensor input shape tidak boleh kosong.',
      );
    }

    final expectedSize = input.shape.fold<int>(
      1,
      (previous, current) => previous * current,
    );

    if (input.data.length != expectedSize) {
      throw ArgumentError(
        'Jumlah data tensor (${input.data.length}) '
        'tidak sesuai dengan shape ${input.shape}. '
        'Expected: $expectedSize.',
      );
    }

    final dims = input.shape
        .map((value) => value.toJS)
        .toList()
        .toJS;

    final tensor = _TensorJS(
      'float32'.toJS,
      input.data.toJS,
      dims,
    );

    final inputNames = session.inputNames.toDart;

    if (inputNames.isEmpty) {
      throw StateError(
        'ONNX model tidak memiliki input.',
      );
    }

    final inputName = inputNames.first.toDart;

    final feeds = JSObject();

    feeds.setProperty(
      inputName.toJS,
      tensor,
    );

    final result = await session
        .run(feeds)
        .toDart;

    final outputNames = session.outputNames.toDart;

    if (outputNames.isEmpty) {
      throw StateError(
        'ONNX model tidak memiliki output.',
      );
    }

    final outputName = outputNames.first.toDart;
    final outputValue = result.getProperty<JSAny?>(
      outputName.toJS,
    );

    if (outputValue == null ||
        outputValue.isUndefined ||
        outputValue.isNull) {
      throw StateError(
        'Output tensor "$outputName" tidak ditemukan '
        'pada hasil inference.',
      );
    }

    final outputTensor = outputValue as _TensorJS;
    final outputData = outputTensor.data.toDart;
    final outputShape = outputTensor.dims
        .toDart
        .map((dimension) => dimension.toDartInt)
        .toList();

    return TensorOutput(
      data: outputData,
      shape: outputShape,
    );
  }

  @override
  Future<void> dispose() async {
    final session = _session;

    if (session == null) {
      return;
    }

    try {
      await session.release().toDart;
    } finally {
      _session = null;
    }
  }
}