/// isolate 세 개(본앱 / 캡슐 오버레이 / 포그라운드 서비스)가 주고받는 메시지 형태.
///
/// `FlutterOverlayWindow.shareData`는 JSONMessageCodec을 쓰므로 Map만 오간다.
/// 문자열 키를 여기저기 하드코딩하면 오타 하나가 조용히 통신을 끊어서, 한곳에 모았다.
///
/// 왜 이렇게 나뉘어 있는가 — 오버레이 isolate는 플러그인이 등록되지 않은 채
/// 생성된다(flutter_overlay_window가 `GeneratedPluginRegistrant`를 부르지 않음).
/// 그래서 캡슐에서는 녹음도 HTTP도 못 하고, 플러그인 자체 채널인
/// `shareData` / `overlayListener`만 쓸 수 있다. 반대로 서비스 isolate는
/// `FlutterEngine(context)`로 만들어져 플러그인이 등록되므로 녹음·분석을 맡는다.
library;

/// 캡슐 → 서비스 명령
const kCmd = 'cmd';
const kCmdToggleRecord = 'toggleRecord';
const kCmdExpand = 'expand';

/// 서비스 → 캡슐/본앱 상태 브로드캐스트
const kState = 'state';
const kRecording = 'recording';
const kElapsedSec = 'elapsedSec';
const kHasRecording = 'hasRecording';
const kAnalyzing = 'analyzing';
const kPhotoPaths = 'photoPaths';
const kResult = 'result';
const kError = 'error';

/// 본앱 → 서비스: 카메라로 찍은 사진 경로를 넘긴다.
/// 촬영은 액티비티가 필요해서 본앱에서만 할 수 있다.
const kCmdSetPhotos = 'setPhotos';
const kPhotos = 'photos';

/// 본앱 → 서비스: 동의 게이트 결과와 함께 분석을 시작한다.
const kCmdAnalyze = 'analyze';
const kConsent = 'consent';

const kCmdCancelAnalysis = 'cancelAnalysis';
const kCmdDiscardRecording = 'discardRecording';

/// 본앱 → 서비스: 지금 상태를 한 번 보내 달라.
///
/// 서비스는 상태가 바뀔 때만 브로드캐스트한다. 녹음을 멈춘 뒤 앱을 열면(또는
/// 앱이 죽었다 다시 살아나면) 바뀔 일이 없어 본앱이 아무 상태도 못 받고,
/// "녹음 없음"으로 잘못 보인다. 앱이 전면에 올 때마다 이걸 보내 맞춘다.
const kCmdRequestState = 'requestState';

/// 본앱 → 서비스: 편집 토글로 고친 결과를 반영한다.
const kCmdUpdateResult = 'updateResult';

/// 서비스가 분석 서버 주소를 알아야 해서, 서비스를 시작할 때 함께 넘긴다.
/// 서비스 isolate는 본앱의 `String.fromEnvironment` 값을 볼 수 없다.
const kApiBaseUrl = 'apiBaseUrl';

Map<String, Object?> cmd(String name, [Map<String, Object?> extra = const {}]) =>
    {kCmd: name, ...extra};
