from pydantic import BaseModel, Field
from typing import List, Literal, Optional

AvatarEmotion = Literal["happy", "talking", "thinking", "celebrating", "encouraging"]

class QuizQuestion(BaseModel):
    question: str = Field(description="سؤال قصير لاختبار فهم الطفل لما تم شرحه.")
    options: List[str] = Field(description="3 أو 4 اختيارات للإجابة.")
    correct_index: int = Field(ge=0, description="رقم الإجابة الصحيحة يبدأ من 0.")
    hint: str = Field(description="تلميح مشجع ولطيف إذا أخطأ الطفل في الإجابة.")

class TutorResponse(BaseModel):
    explanation: str = Field(description="شرح مبسط ومرح ومشجع يناسب طفلاً في عمر 7 إلى 10 سنوات.")
    referenced_page: Optional[int] = Field(default=None, description="رقم الصفحة في ملف الـ PDF التي تحتوي على المعلومة.")
    avatar_emotion: AvatarEmotion = Field(description="حالة الشخصية الكرتونية: happy, talking, thinking, celebrating, encouraging")
    follow_up_quiz: Optional[QuizQuestion] = Field(default=None, description="سؤال تفاعلي للتأكد من استيعاب النقطة المشروحة.")

class ChatRequest(BaseModel):
    gemini_file_name: str
    student_message: str