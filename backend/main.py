import os
import shutil
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from models import ChatRequest, TutorResponse
from gemini_service import upload_pdf_to_gemini, ask_tutor_gemini

app = FastAPI(title="Kids AI Tutor Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

@app.post("/upload")
def upload_material(file: UploadFile = File(...)):
    safe_filename = os.path.basename(file.filename or "")
    if not safe_filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Only PDF files are allowed.")
    
    local_path = os.path.join(UPLOAD_DIR, safe_filename)
    with open(local_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
        
    try:
        gemini_file_name = upload_pdf_to_gemini(local_path)
        return {
            "status": "success",
            "filename": safe_filename,
            "gemini_file_name": gemini_file_name
        }
    except Exception as e:
        if os.path.exists(local_path):
            os.remove(local_path)
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/ask", response_model=TutorResponse)
def ask_tutor(request: ChatRequest):
    try:
        tutor_reply = ask_tutor_gemini(
            gemini_file_name=request.gemini_file_name,
            student_message=request.student_message
        )
        return tutor_reply
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))