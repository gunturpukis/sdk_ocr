import 'inference_session.dart';

class InferenceSessionImpl implements InferenceSession {
  @override
  Future<void> load(String modelPath) {
    throw UnsupportedError('Platform tidak didukung untuk InferenceSession.');
  }

  @override
  Future<TensorOutput> run(TensorInput input) {
    throw UnsupportedError('Platform tidak didukung untuk InferenceSession.');
  }

  @override
  Future<void> dispose() async {}
}
