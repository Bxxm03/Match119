import 'dart:io';

import 'package:flutter/material.dart';

import '../logic/copy_text.dart';
import '../model/analysis_result.dart';
import '../platform/assistant_controller.dart';
import '../theme/tokens.dart';
import 'capsule.dart';

/// 축소(캡슐만) ↔ 확대(작업 화면)를 담는 껍데기.
class CapsuleScaffold extends StatefulWidget {
  const CapsuleScaffold({
    super.key,
    required this.controller,
    required this.state,
    required this.expanded,
    required this.onExpand,
    required this.onCollapse,
    required this.onAnalyze,
  });

  final AssistantController controller;
  final AssistantState state;
  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final VoidCallback onAnalyze;

  @override
  State<CapsuleScaffold> createState() => _CapsuleScaffoldState();
}

class _CapsuleScaffoldState extends State<CapsuleScaffold> {
  /// 캡슐 위치. 실제 안드로이드에서는 시스템 오버레이 창의 위치가 되고,
  /// 여기서는 화면 안 좌표로 흉내 낸다. 드래그로 옮긴 자리를 기억한다.
  Offset? _capsulePos;

  @override
  void didUpdateWidget(CapsuleScaffold old) {
    super.didUpdateWidget(old);
    _showErrorIfAny(old.state.error);
  }

  void _showErrorIfAny(String? previous) {
    final error = widget.state.error;
    if (error == null || error == previous) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: RapidColors.graphite2),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.expanded) {
      return _ExpandedView(
        controller: widget.controller,
        state: widget.state,
        onCollapse: widget.onCollapse,
        onAnalyze: widget.onAnalyze,
      );
    }
    return _CollapsedView(
      state: widget.state,
      position: _capsulePos,
      onMove: (p) => setState(() => _capsulePos = p),
      onMicTap: widget.controller.toggleRecording,
      onExpandTap: widget.onExpand,
    );
  }
}

/// 축소 상태. 실앱에서는 여기 배경이 진짜 119 시스템 화면이다.
class _CollapsedView extends StatelessWidget {
  const _CollapsedView({
    required this.state,
    required this.position,
    required this.onMove,
    required this.onMicTap,
    required this.onExpandTap,
  });

  final AssistantState state;
  final Offset? position;
  final ValueChanged<Offset> onMove;
  final VoidCallback onMicTap;
  final VoidCallback onExpandTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final pos = position ??
                Offset(box.maxWidth - 260, box.maxHeight - 140);
            return Stack(
              children: [
                const Positioned.fill(child: _BackdropPlaceholder()),
                Positioned(
                  left: pos.dx.clamp(0.0, box.maxWidth - 60),
                  top: pos.dy.clamp(0.0, box.maxHeight - 60),
                  child: GestureDetector(
                    onPanUpdate: (d) => onMove(pos + d.delta),
                    child: Capsule(
                      recording: state.recording,
                      recordedSeconds: state.recordedSeconds,
                      resultPending: state.result != null,
                      onMicTap: onMicTap,
                      onExpandTap: onExpandTap,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 기기 없이 확인할 때 캡슐 뒤가 빈 화면이면 어색하므로 자리만 표시한다.
/// 실앱에서는 이 위젯이 없고, 대원이 보던 119 화면이 그대로 배경이 된다.
class _BackdropPlaceholder extends StatelessWidget {
  const _BackdropPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: RapidColors.carbon,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(RapidSpace.xl),
          child: Text(
            '실제 기기에서는 이 자리에\n기존 119 시스템 화면이 보입니다',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: RapidColors.fog.withValues(alpha: 0.5),
              fontSize: 13,
              height: 1.7,
            ),
          ),
        ),
      ),
    );
  }
}

/// 확대 상태 — 상태에 따라 패널 / 분석중 / 결과를 보여 준다.
class _ExpandedView extends StatelessWidget {
  const _ExpandedView({
    required this.controller,
    required this.state,
    required this.onCollapse,
    required this.onAnalyze,
  });

  final AssistantController controller;
  final AssistantState state;
  final VoidCallback onCollapse;
  final VoidCallback onAnalyze;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: switch (state.screen) {
              AssistantScreen.panel => PanelView(
                  controller: controller,
                  state: state,
                  onCollapse: onCollapse,
                  onAnalyze: onAnalyze,
                ),
              AssistantScreen.analyzing => AnalyzingView(
                  onCollapse: onCollapse,
                  onCancel: controller.cancelAnalysis,
                ),
              AssistantScreen.result => ResultView(
                  controller: controller,
                  result: state.result!,
                  onCollapse: onCollapse,
                ),
            },
          ),
        ),
      ),
    );
  }
}

/// 상단 네비 — 어느 작업 화면에나 "축소"가 있어야 한다.
class _TopNav extends StatelessWidget {
  const _TopNav({required this.onCollapse, this.onBack, this.trailing});

  final VoidCallback onCollapse;
  final VoidCallback? onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null)
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.chevron_left, size: 18),
            label: const Text('이전'),
            style: TextButton.styleFrom(foregroundColor: RapidColors.fog),
          ),
        const Spacer(),
        ?trailing,
        TextButton.icon(
          onPressed: onCollapse,
          icon: const Icon(Icons.close_fullscreen_rounded, size: 16),
          label: const Text('축소'),
          style: TextButton.styleFrom(foregroundColor: RapidColors.fog),
        ),
      ],
    );
  }
}

/// 스펙 05절 패널 — 녹음·사진을 확인하고 분석을 시작한다.
class PanelView extends StatelessWidget {
  const PanelView({
    super.key,
    required this.controller,
    required this.state,
    required this.onCollapse,
    required this.onAnalyze,
  });

  final AssistantController controller;
  final AssistantState state;
  final VoidCallback onCollapse;
  final VoidCallback onAnalyze;

  @override
  Widget build(BuildContext context) {
    final hasRecording = state.hasRecording;

    return Padding(
      padding: const EdgeInsets.all(RapidSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopNav(onCollapse: onCollapse),
          const SizedBox(height: RapidSpace.lg),
          _Card(
            child: Row(
              children: [
                Icon(
                  Icons.mic_rounded,
                  size: 18,
                  color: hasRecording ? RapidColors.vital : RapidColors.fog,
                ),
                const SizedBox(width: RapidSpace.md),
                Expanded(
                  child: Text(
                    hasRecording
                        ? '${formatDuration(state.recordedSeconds)} 녹음됨'
                        : '녹음 없음',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: hasRecording
                          ? RapidColors.paper
                          : RapidColors.fog,
                      fontFamily: hasRecording ? RapidFont.mono : null,
                    ),
                  ),
                ),
                if (hasRecording)
                  IconButton(
                    onPressed: () async {
                      await controller.discardRecording();
                      onCollapse();
                    },
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    color: RapidColors.fog,
                    tooltip: '삭제하고 다시 녹음',
                  ),
              ],
            ),
          ),
          if (!hasRecording) ...[
            const SizedBox(height: RapidSpace.sm),
            const Text(
              // 녹음은 언제나 캡슐 마이크로 시작한다 — 패널엔 녹음 버튼이 없다.
              '축소한 뒤 캡슐의 마이크를 눌러 녹음하세요.',
              style: TextStyle(fontSize: 12, color: RapidColors.fog),
            ),
          ],
          const SizedBox(height: RapidSpace.md),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '사진 (${state.photoCount}/3)',
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1,
                    fontWeight: FontWeight.bold,
                    color: RapidColors.fog,
                  ),
                ),
                const SizedBox(height: RapidSpace.md),
                Wrap(
                  spacing: RapidSpace.md,
                  runSpacing: RapidSpace.md,
                  children: [
                    for (var i = 0; i < state.photoPaths.length; i++)
                      _PhotoTile(
                        path: state.photoPaths[i],
                        onRemove: () => controller.removePhoto(i),
                      ),
                    if (state.photoCount < 3 && hasRecording)
                      _AddPhotoTile(onTap: controller.addPhoto),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          FilledButton(
            // 사진 선택 즉시 자동분석이 아니라 명시적 버튼이다. 원터치에서
            // 한 단계 늘어나는 대신 잘못 녹음·촬영했을 때 고칠 여지를 얻는다.
            onPressed: state.canAnalyze ? onAnalyze : null,
            child: const Text('분석하기'),
          ),
        ],
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.path, required this.onRemove});

  /// 촬영본 경로. Fake 구현은 실제 파일이 없어 빈 문자열을 주므로,
  /// 읽을 수 없으면 자리 표시 아이콘으로 떨어진다.
  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 72,
            height: 72,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: RapidColors.graphite2,
              borderRadius: BorderRadius.circular(RapidRadius.button),
              border: Border.all(color: RapidColors.line),
            ),
            child: path.isEmpty
                ? const _PhotoPlaceholder()
                : Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    // 촬영 직후 파일이 아직 없거나 지워진 경우에도 화면이
                    // 깨지지 않게 한다.
                    errorBuilder: (_, _, _) => const _PhotoPlaceholder(),
                  ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: RapidColors.carbon,
                  shape: BoxShape.circle,
                  border: Border.all(color: RapidColors.line),
                ),
                child: const Icon(Icons.close,
                    size: 14, color: RapidColors.paper),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) => const Icon(
        Icons.photo_camera_rounded,
        color: RapidColors.fog,
        size: 24,
      );
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RapidRadius.button),
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(RapidRadius.button),
          border: Border.all(
            color: RapidColors.line,
            width: 1.5,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
        child: const Icon(Icons.add, color: RapidColors.fog, size: 28),
      ),
    );
  }
}

/// 스펙 07절 분석 중.
///
/// "축소"와 "이전"이 다른 동작이라는 점이 중요하다 — 축소는 분석을 백그라운드로
/// 넘기고(처치를 방해하지 않는다), 이전은 분석 자체를 취소한다.
class AnalyzingView extends StatelessWidget {
  const AnalyzingView({
    super.key,
    required this.onCollapse,
    required this.onCancel,
  });

  final VoidCallback onCollapse;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RapidSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopNav(onCollapse: onCollapse, onBack: onCancel),
          const Spacer(),
          const Center(
            child: Column(
              children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: RapidColors.vital,
                  ),
                ),
                SizedBox(height: RapidSpace.xl),
                Text(
                  'AI가 대화·사진을 분석하는 중...',
                  style: TextStyle(fontSize: 14, color: RapidColors.fog),
                ),
                SizedBox(height: RapidSpace.sm),
                Text(
                  '축소해도 분석은 계속됩니다.',
                  style: TextStyle(fontSize: 12, color: RapidColors.fog),
                ),
              ],
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// 스펙 08절 결과 확인.
class ResultView extends StatefulWidget {
  const ResultView({
    super.key,
    required this.controller,
    required this.result,
    required this.onCollapse,
  });

  final AssistantController controller;
  final AnalysisResult result;
  final VoidCallback onCollapse;

  @override
  State<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<ResultView> {
  bool _editing = false;

  /// 종결 액션은 둘 다 "즉시 복사 → 토스트 → 자동 축소"로 끝난다.
  /// 확인·미리보기·복사 3단계를 클릭 한 번으로 합친 것.
  Future<void> _finish({required bool keepImpression}) async {
    final text = keepImpression
        ? CopyText.withImpression(widget.result)
        : CopyText.factsOnly(widget.result);

    await widget.controller.copyToClipboard(text);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(keepImpression ? '복사됨' : '사실 요약 복사됨'),
        duration: const Duration(milliseconds: 1300),
        backgroundColor: RapidColors.graphite2,
      ),
    );
    widget.onCollapse();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;

    return Padding(
      padding: const EdgeInsets.all(RapidSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopNav(
            onCollapse: widget.onCollapse,
            trailing: TextButton(
              onPressed: () => setState(() => _editing = !_editing),
              style: TextButton.styleFrom(foregroundColor: RapidColors.vital),
              child: Text(_editing ? '완료' : '편집'),
            ),
          ),
          const SizedBox(height: RapidSpace.sm),
          const Text(
            '결과 확인',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: RapidColors.paper,
            ),
          ),
          const SizedBox(height: RapidSpace.lg),
          Expanded(
            child: ListView(
              children: [
                _Card(
                  child: Column(
                    children: [
                      for (final f in ResultField.values) ...[
                        if (f != ResultField.values.first)
                          const Divider(height: RapidSpace.xl),
                        _FieldRow(
                          field: f,
                          value: f.valueOf(r),
                          editing: _editing,
                          onChanged: (v) =>
                              widget.controller.updateResult(f.apply(r, v)),
                        ),
                      ],
                    ],
                  ),
                ),
                if (r.aiImpression.isNotEmpty) ...[
                  const SizedBox(height: RapidSpace.md),
                  _ImpressionCard(
                    impression: r.aiImpression,
                    reasons: r.reasons,
                  ),
                ],
                const SizedBox(height: RapidSpace.md),
                const Text(
                  '※ 기존 시스템엔 이걸 위한 별도 필드가 없어 기타 칸 끝에 덧붙여 '
                  '전달됩니다. 의심소견·근거 모두 "복사"에만 포함됩니다 — '
                  '"사실만 남기기"는 틀렸다고 판단한 AI 해석이라 소견·근거를 '
                  '둘 다 제외합니다.',
                  style: TextStyle(
                    fontSize: 11,
                    color: RapidColors.fog,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: RapidSpace.md),
          FilledButton(
            onPressed: () => _finish(keepImpression: true),
            child: const Text('복사'),
          ),
          const SizedBox(height: RapidSpace.sm),
          OutlinedButton(
            onPressed: () => _finish(keepImpression: false),
            child: const Text('사실만 남기기'),
          ),
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.field,
    required this.value,
    required this.editing,
    required this.onChanged,
  });

  final ResultField field;
  final String value;
  final bool editing;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          field.label,
          style: const TextStyle(
            fontSize: 10,
            letterSpacing: 1,
            fontWeight: FontWeight.bold,
            color: RapidColors.fog,
          ),
        ),
        const SizedBox(height: RapidSpace.xs),
        if (editing)
          TextFormField(
            // 저장 버튼이 없다 — 다음 액션이 곧 확정이므로 입력 즉시 반영한다.
            initialValue: value,
            onChanged: onChanged,
            maxLines: null,
            style: const TextStyle(fontSize: 14, color: RapidColors.paper),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: RapidColors.graphite2,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: RapidSpace.md,
                vertical: RapidSpace.sm,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RapidSpace.sm),
                borderSide: const BorderSide(color: RapidColors.line),
              ),
            ),
          )
        else
          Text(
            value.isEmpty ? '—' : value,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: value.isEmpty ? RapidColors.fog : RapidColors.paper,
            ),
          ),
      ],
    );
  }
}

/// AI 종합소견 — amber로 "참고용"임을 색으로 구분한다.
class _ImpressionCard extends StatelessWidget {
  const _ImpressionCard({required this.impression, required this.reasons});

  final String impression;
  final List<String> reasons;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(RapidSpace.lg),
      decoration: BoxDecoration(
        color: RapidColors.amberDim,
        borderRadius: BorderRadius.circular(RapidRadius.card),
        border: Border.all(color: RapidColors.amber.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AI 종합소견 · 참고용',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1,
              fontWeight: FontWeight.bold,
              color: RapidColors.amber,
            ),
          ),
          const SizedBox(height: RapidSpace.sm),
          Text(
            impression,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: RapidColors.paper,
            ),
          ),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: RapidSpace.md),
            Divider(color: RapidColors.amber.withValues(alpha: 0.25), height: 1),
            const SizedBox(height: RapidSpace.md),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: RapidSpace.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('· ',
                        style: TextStyle(color: RapidColors.amber)),
                    Expanded(
                      child: Text(
                        reason,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: Color(0xFFD9C39A),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(RapidSpace.lg),
      decoration: BoxDecoration(
        color: RapidColors.graphite,
        borderRadius: BorderRadius.circular(RapidRadius.card),
      ),
      child: child,
    );
  }
}
