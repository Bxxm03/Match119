"""모델에 주는 지시문(프롬프트)과 응답 형식(스키마)을 한곳에 둔다.

역할 분리:
- 프롬프트 본문은 Firestore `prompts/current`에서 읽는다(앱 업데이트 없이 개선).
  여기 있는 DEFAULT_PROMPT_TEMPLATE은 그 문서를 처음 올릴 때(seed_prompt.py)와
  Firestore를 못 읽을 때 쓰는 내장 기본값이다.
- 응답 스키마는 앱의 AnalysisResult.fromJson과 맞물린 계약이라 코드가 소유한다.
  프롬프트를 고쳐도 앱 파싱이 깨지지 않게, 스키마는 Firestore로 옮기지 않는다.
"""

from google.genai import types

# 대화 원문 표현 + 의학용어 병기(기본 필드) / ai_impression은 질환군명 수준까지만 / reasons는 평이한 관찰언어
# — EMS_기획안_v2.md 03번 섹션 스키마·원칙 그대로.
#
# {now}는 요청 시점의 서울 시각(HH:MM)으로 치환된다. 대화에서 "20분 전"처럼
# 상대시간으로 말하는 게 보통이라, 대원이 그걸 다시 시계로 환산하는 수고를
# 없애려고 모델이 직접 절대시각을 계산하게 한다. JSON 예시의 중괄호와
# 충돌하지 않도록 str.format이 아니라 str.replace로 치환한다.
DEFAULT_PROMPT_VERSION = "builtin"

DEFAULT_PROMPT_TEMPLATE = """다음 오디오는 구급대원과 환자(또는 보호자) 간 실제 대화 녹음이다. 사진이 함께 제공되면 시각적 소견도 참고하라.
현재 시각은 {now}이다.
정해진 응답 스키마의 각 필드 설명에 맞춰 채워라.

각 필드는 대화에서 그 내용이 직접 언급된 경우에만 채워라. 필드별로 독립적으로
판단하라 — 예를 들어 주증상은 나왔지만 발병시점은 안 나왔으면, 주증상만 채우고
발병시점은 빈 문자열로 남겨라. 다른 필드에 내용이 있다고 해서, 또는 그럴듯해
보인다고 해서 언급되지 않은 필드를 추측해서 채우지 마라.
오디오가 너무 짧거나, 잡음뿐이거나, 실제 대화 내용을 알아들을 수 없으면
절대로 그럴듯한 상황을 지어내지 마라 — 그런 경우 모든 필드를 빈 문자열(reasons는
빈 배열)로 남겨라."""


def _text(description: str) -> types.Schema:
    return types.Schema(type=types.Type.STRING, description=description)


_FIELDS = {
    "chief_complaint": _text(
        "주증상 — 환자가 말한 표현을 기록체로 적고 한국어 의학용어를 괄호로 병기하라"
        "(예: 가슴이 아픔(흉통), 숨이 참(호흡곤란)). 증상이 여럿이면 쉼표로 나열하라."
    ),
    "past_history": _text(
        "과거력 — 환자 본인의 병력, 수술력, 복용약, 알레르기, 다니는 병원을 적어라. "
        "대원이 그 항목을 직접 물었고 '없다'고 답한 경우에만 '알레르기 없음'처럼 적어라. "
        "대원이 묻지 않은 병명이나 항목을 '~없음'으로 덧붙이지 마라. "
        "가족의 병력은 여기에 넣지 마라(기타에 적는다)."
    ),
    "onset": _text(
        "발병시점 — 대화에 '20분 전'처럼 상대시간으로 나오면 '원래 표현(계산된 절대시각 HH:MM)' "
        "형식으로 적어라(예: 현재 14:52, '20분 전' → '20분전(14:32)'). "
        "처음부터 시각으로 말했으면 그 시각만 적어라. "
        "상대시간이 여러 개면 각각 시각을 붙여라(예: 40분 전(22:03) 시작, 20분 전(22:23) 심해짐)."
    ),
    "last_normal_time": _text(
        "마지막 정상확인시간 — onset과 같은 표기 방식(원래 표현+절대시각). "
        "onset과 별개로 대화에서 명시적으로 언급된 경우에만 채워라 — 대화에 따로 나온 게 "
        "없으면 onset과 같은 값을 넣지 말고 빈 문자열로 남겨라."
    ),
    "guardian": _text(
        "보호자 — 보호자가 환자에게 누구인지 적어라(예: 보호자가 환자의 아내면 '아내'). "
        "관계를 대화에서 직접 말하지 않았으면 추측하지 말고 빈 문자열로 남겨라. "
        "대화에서 말한 상태가 있으면 괄호로 덧붙여라(예: 아버지(오는 중)). "
        "'동승'은 함께 탄다고 대화에서 말한 경우에만 적어라. "
        "보호자에 대해 묻지도 답하지도 않았으면 빈 문자열로 남겨라."
    ),
    "etc": _text(
        "기타 — 사고·발병 경위(어디서/어떻게), 증상이 나타나는 조건(예: 일어날 때), "
        "통증 양상·강도·퍼지는 부위, 횟수, 가족력('가족력: 아버지 심근경색' 형식), "
        "그 밖에 환자·보호자가 말한 사실 중 다른 필드에 들어가지 않는 내용."
    ),
    "ai_impression": _text(
        "의심 질환군 — 대원이 현장에서 쓰는 질환군명 수준까지만, 세부 임상분류 제외. "
        "1차 분류 보조용이며 확정 진단이 아니다"
    ),
    "reasons": types.Schema(
        type=types.Type.ARRAY,
        description="ai_impression의 근거 — 평이한 관찰언어로만, 의학용어·진단명 쓰지 않음",
        items=types.Schema(type=types.Type.STRING),
    ),
}

# 모든 필드를 required로 둬서 모델이 키를 빼먹지 못하게 하고, 언급이 없으면
# 빈 문자열을 넣게 한다(키 누락 대신 빈 값 — 앱 화면 표시가 단순해진다).
RESPONSE_SCHEMA = types.Schema(
    type=types.Type.OBJECT,
    properties=_FIELDS,
    required=list(_FIELDS),
    property_ordering=list(_FIELDS),
)

EMPTY_RESULT = {
    "chief_complaint": "",
    "past_history": "",
    "onset": "",
    "last_normal_time": "",
    "guardian": "",
    "etc": "",
    "ai_impression": "",
    "reasons": [],
}
