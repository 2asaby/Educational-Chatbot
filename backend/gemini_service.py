import os
from dotenv import load_dotenv
from google import genai
from google.genai import errors, types
from models import TutorResponse

load_dotenv()

client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))

FALLBACK_MODELS = [
    "gemini-3.1-flash-lite",
    "gemini-3.5-flash-lite",
    "gemini-3.5-flash",
    "gemini-3.8-flash",
    "gemini-3.7-flash",
    "gemini-3.6-flash",
]

SYSTEM_PROMPT = """
أنت معلم ذكي، مرح، وصبور للأطفال (من سن 7 إلى 10 سنوات).
القواعد الصارمة:
1. اعتمد حصرياً على ملف الـ PDF المرفق في الشرح. إذا سأل الطفل عن شيء خارج الملف، اعتذر بلطف واطلب منه العودة لدرس اليوم.
2. اشرح المعلومة بلغة بسيطة جداً وقصصية، وحدد رقم الصفحة (referenced_page) التي تشرح منها بدقة.
3. بعد كل شرح، اطرح سؤالاً تفاعلياً واحداً (follow_up_quiz) للتأكد من فهم الطفل.
4. التزم تماماً بقواعد الأمان، ولا تناقش أي مواضيع غير تعليمية أو غير مناسبة للأطفال.
5. لا تستخدم كلمة "يا بطل" أو "أهلاً بك يا بطل" نهائياً في الردود.
"""

def upload_pdf_to_gemini(file_path: str) -> str:
    """Uploads a local PDF to Gemini File API and returns its unique URI name."""
    uploaded_file = client.files.upload(file=file_path)
    return uploaded_file.name

def ask_tutor_gemini(gemini_file_name: str, student_message: str) -> TutorResponse:
    """Queries Gemini using the uploaded PDF reference and returns structured JSON."""
    pdf_file = client.files.get(name=gemini_file_name)
    config = types.GenerateContentConfig(
        system_instruction=SYSTEM_PROMPT,
        temperature=0.3,
        response_mime_type="application/json",
        response_schema=TutorResponse,
        safety_settings=[
            types.SafetySetting(
                category=types.HarmCategory.HARM_CATEGORY_HARASSMENT,
                threshold=types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
            ),
            types.SafetySetting(
                category=types.HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
                threshold=types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
            ),
            types.SafetySetting(
                category=types.HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
                threshold=types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
            ),
            types.SafetySetting(
                category=types.HarmCategory.HARM_CATEGORY_HATE_SPEECH,
                threshold=types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
            ),
        ],
    )

    last_error = None
    response = None
    for model_name in FALLBACK_MODELS:
        try:
            response = client.models.generate_content(
                model=model_name,
                contents=[pdf_file, student_message],
                config=config,
            )
            break
        except errors.APIError as e:
            last_error = e
            if e.code in (429, 500, 503, 504):
                continue
            raise

    if response is None and last_error is not None:
        raise last_error

    if not response or not response.text:
        return TutorResponse(
            explanation="عذراً يا صديقي الصغير، لا يمكنني الإجابة عن هذا السؤال. دعنا نعود إلى درسنا الجميل في الملف!",
            referenced_page=None,
            avatar_emotion="encouraging",
            follow_up_quiz=None,
        )
    return TutorResponse.model_validate_json(response.text)