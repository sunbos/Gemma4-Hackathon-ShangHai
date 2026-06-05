from fastapi import FastAPI
from fastapi.responses import RedirectResponse
from web.api.app import app as web_app
from web2.api.app import app as web2_app

main_app = FastAPI()

main_app.mount("/web", web_app)
main_app.mount("/web2", web2_app)

@main_app.get("/")
async def root():
    return RedirectResponse(url="/web")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(main_app, host="0.0.0.0", port=8000)