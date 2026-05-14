from flask import Flask, request, jsonify, render_template_string
import boto3
import json
import os
import re
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import unquote
from pathlib import Path

app = Flask(__name__)

# ------------------------------------------------------------------ #
#  Config
# ------------------------------------------------------------------ #
AWS_REGION        = "us-east-1"
KNOWLEDGE_BASE_ID = "MHADZDLOPE"
IMAGE_BUCKET      = "variety-bucket-514316422605-us-east-1-an"
JSON_BUCKET       = "result-buckett"
JSON_PREFIX       = "aws/bedrock/knowledge_bases/ASC-VAR/"
AWS_CREDS_PATH    = "/home/as5289/PYTHON/CHAT"
BEDROCK_MODEL_ARN = "arn:aws:bedrock:us-east-1:514316422605:inference-profile/us.anthropic.claude-sonnet-4-6"
SESSIONS_DIR      = Path("/home/as5289/PYTHON/CHAT/SESSIONS")
SESSION_MAX_BYTES = 10 * 1024
SESSION_TTL_SECS  = 5 * 60

os.environ.setdefault("AWS_SHARED_CREDENTIALS_FILE", os.path.join(AWS_CREDS_PATH, "credentials"))
os.environ.setdefault("AWS_CONFIG_FILE",             os.path.join(AWS_CREDS_PATH, "config"))

SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

bedrock = boto3.client("bedrock-agent-runtime", region_name=AWS_REGION)
s3      = boto3.client("s3", region_name=AWS_REGION)

# ------------------------------------------------------------------ #
#  Keyword taxonomy
# ------------------------------------------------------------------ #
KEYWORDS = [
    "Abstract","Americana","Animal Skin","Antique","Authentic","Basic","Basket Weave",
    "Block","Border","Botanical","Braid","Braided","Casual","Check","Checker Board",
    "Chevron","Circle","Classical","Damask","Diamond","Distressed","Farmhouse","Floral",
    "Fretwork","Geometric","Gingham","Global","Herringbone","Hooked","Ikat","Juvenile",
    "Kilim","Leaf","Marble","Modern","Moroccan","Novelty","Ogee","Ombre","Oval","Panel",
    "Persian","Plaid","Scroll","Sisal","Soft Modern","Southwest","Stripe","Textured",
    "Traditional","Transitional","Trellis","Tribal","Vintage","Watercolor","Wave","Weathered"
]
TAXONOMY_STR = ", ".join(KEYWORDS)

# ------------------------------------------------------------------ #
#  Session management
# ------------------------------------------------------------------ #

def session_path(sid):
    return SESSIONS_DIR / f"{sid}.json"

def load_session(sid):
    p = session_path(sid)
    try:
        if p.exists():
            data = json.loads(p.read_text())
            if time.time() - data.get("last_active", 0) < SESSION_TTL_SECS:
                return data
            p.unlink(missing_ok=True)
    except Exception:
        pass
    return {"history": [], "last_active": time.time()}

def save_session(sid, data):
    data["last_active"] = time.time()
    raw = json.dumps(data)
    while len(raw.encode()) > SESSION_MAX_BYTES and len(data["history"]) > 1:
        data["history"].pop(0)
        raw = json.dumps(data)
    session_path(sid).write_text(raw)

def delete_session(sid):
    session_path(sid).unlink(missing_ok=True)

def cleanup_sessions():
    while True:
        time.sleep(60)
        try:
            now = time.time()
            for p in SESSIONS_DIR.glob("*.json"):
                try:
                    data = json.loads(p.read_text())
                    if now - data.get("last_active", 0) > SESSION_TTL_SECS:
                        p.unlink(missing_ok=True)
                except Exception:
                    p.unlink(missing_ok=True)
        except Exception:
            pass

threading.Thread(target=cleanup_sessions, daemon=True).start()

# ------------------------------------------------------------------ #
#  Query expansion
# ------------------------------------------------------------------ #

def expand_query(query):
    import urllib.request
    payload = json.dumps({
        "model": "claude-sonnet-4-6",
        "max_tokens": 200,
        "system": (
            "You are a rug industry search expert. Expand the user's search query into richer "
            "terms that would appear in professional rug descriptions. Include synonyms, related "
            "design elements, pattern names, and colour variations. "
            "Where relevant, reference terms from this official product taxonomy: "
            f"{TAXONOMY_STR}. "
            "Return only the expanded query as a single paragraph — no explanation, no preamble."
        ),
        "messages": [{"role": "user", "content": f"Expand this rug search query: {query}"}]
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=payload,
        headers={"x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            expanded = data["content"][0]["text"]
            print(f"Expanded: '{query[:60]}' -> '{expanded[:80]}...'")
            return expanded
    except Exception as e:
        print(f"Query expansion failed: {e}")
        return query

# ------------------------------------------------------------------ #
#  RAG summary
# ------------------------------------------------------------------ #

RAG_SYSTEM = (
    "You are an expert rug analyst for a high-end rug retailer. "
    "Help sales representatives find the right rug for each customer. "
    "Use professional sales-oriented language referencing specific patterns, "
    "colour palettes, and design characteristics. Be concise — 2-3 sentences maximum."
)

def rag_summarise(query, history=None):
    try:
        context = ""
        if history:
            context = "Previous searches in this session:\n"
            for h in history[-3:]:
                context += f"- User searched: \"{h['query']}\"\n"
            context += "\nCurrent search: "
        response = bedrock.retrieve_and_generate(
            input={"text": context + query},
            retrieveAndGenerateConfiguration={
                "type": "KNOWLEDGE_BASE",
                "knowledgeBaseConfiguration": {
                    "knowledgeBaseId": KNOWLEDGE_BASE_ID,
                    "modelArn": BEDROCK_MODEL_ARN,
                    "generationConfiguration": {
                        "promptTemplate": {
                            "textPromptTemplate": RAG_SYSTEM + "\n\n$search_results$\n\n$output_format_instructions$"
                        }
                    },
                    "retrievalConfiguration": {
                        "vectorSearchConfiguration": {"numberOfResults": 10}
                    }
                }
            }
        )
        return response["output"]["text"]
    except Exception as e:
        print(f"RAG summarise error: {e}")
        return "Results retrieved — summary unavailable."

# ------------------------------------------------------------------ #
#  Presign
# ------------------------------------------------------------------ #

def presign(key, expires=3600):
    if not key:
        return None
    try:
        clean_key = unquote(key)
        return s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": IMAGE_BUCKET, "Key": clean_key},
            ExpiresIn=expires,
        )
    except Exception as e:
        print(f"Pre-sign error for {key}: {e}")
        return None

# ------------------------------------------------------------------ #
#  Retrieve + full JSON fetch
# ------------------------------------------------------------------ #

def retrieve_rugs(query, max_results=9, exclude_ids=None):
    exclude_ids = set(exclude_ids or [])
    fetch_count = max_results + len(exclude_ids) + 9

    response = bedrock.retrieve(
        knowledgeBaseId=KNOWLEDGE_BASE_ID,
        retrievalQuery={"text": query},
        retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": fetch_count}},
    )

    seen = {}
    for hit in response.get("retrievalResults", []):
        try:
            uri    = hit.get("location", {}).get("s3Location", {}).get("uri", "")
            fname  = uri.split("/")[-1]
            rug_id = fname.split("-")[0]
            if not rug_id:
                continue
            score = round(hit.get("score", 0) * 100)
            if rug_id not in seen or score > seen[rug_id]["score"]:
                seen[rug_id] = {"score": score, "fname": fname}
        except Exception as e:
            print(f"Skipping hit: {e}")

    def fetch_rug(rug_id, meta):
        try:
            json_fname = re.sub(r'\.(PNG|png|JPG|jpg|jpeg|JPEG)$', '.json', meta["fname"])
            json_key   = JSON_PREFIX + json_fname
            obj  = s3.get_object(Bucket=JSON_BUCKET, Key=json_key)
            data = json.loads(obj["Body"].read().decode("utf-8"))

            analysis = data.get("analysis", {})
            source   = data.get("source_config", {})

            img_key = source.get("s3_image_key", "")
            if not img_key:
                img_key = unquote(meta["fname"])
            img_url = presign(img_key) if img_key else None

            size_match = re.search(r"-(\d+)x(\d+)-", meta["fname"])
            width  = size_match.group(1) if size_match else data.get("width", "—")
            height = size_match.group(2) if size_match else data.get("height", "—")

            return {
                "rug_id":           rug_id,
                "img_url":          img_url,
                "score":            meta["score"],
                "style":            analysis.get("style", "—"),
                "pattern_type":     analysis.get("pattern_type", "—"),
                "primary_colors":   analysis.get("primary_colors", []),
                "secondary_colors": analysis.get("secondary_colors", []),
                "design_elements":  analysis.get("design_elements", []),
                "tone":             analysis.get("tone", "—"),
                "complexity":       analysis.get("complexity", "—"),
                "origin":           analysis.get("origin", "—"),
                "material":         analysis.get("material", "—"),
                "width":            width,
                "height":           height,
                "description":      analysis.get("description_raw", ""),
            }
        except Exception as e:
            print(f"Failed to fetch JSON for {rug_id}: {e}")
            return None

    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(fetch_rug, rug_id, meta): rug_id for rug_id, meta in seen.items()}
        rugs = [f.result() for f in as_completed(futures) if f.result() is not None]

    rugs = [r for r in rugs if r["rug_id"] not in exclude_ids]
    return sorted(rugs, key=lambda r: r["score"], reverse=True)[:max_results]

# ------------------------------------------------------------------ #
#  Reranking
# ------------------------------------------------------------------ #

def rerank_rugs(query, rugs):
    try:
        sources = [
            {
                "type": "INLINE",
                "inlineDocumentSource": {
                    "type": "TEXT",
                    "textDocument": {
                        "text": (
                            f"Style: {r['style']}. Pattern: {r['pattern_type']}. "
                            f"Colors: {', '.join(r['primary_colors'])}. "
                            f"Tone: {r['tone']}. {r['description'][:300]}"
                        )
                    }
                }
            }
            for r in rugs
        ]
        response = bedrock.rerank(
            rerankingConfiguration={
                "type": "BEDROCK_RERANKING_MODEL",
                "bedrockRerankingConfiguration": {
                    "modelConfiguration": {
                        "modelArn": "arn:aws:bedrock:us-east-1::foundation-model/cohere.rerank-v3-5:0"
                    },
                    "numberOfResults": len(rugs)
                }
            },
            sources=sources,
            queries=[{"type": "TEXT", "textQuery": {"text": query}}]
        )
        reranked = []
        for item in response["results"]:
            idx   = item["index"]
            score = round(item["relevanceScore"] * 100)
            rug   = dict(rugs[idx])
            rug["score"] = score
            reranked.append(rug)
        return reranked
    except Exception as e:
        print(f"Reranking failed, using original order: {e}")
        return rugs

# ------------------------------------------------------------------ #
#  Routes
# ------------------------------------------------------------------ #

@app.route("/")
def index():
    return render_template_string(HTML)

@app.route("/keywords")
def keywords():
    import random
    return jsonify(random.sample(KEYWORDS, min(8, len(KEYWORDS))))

@app.route("/session/delete", methods=["POST"])
def delete_session_route():
    body = request.get_json()
    sid  = (body.get("session_id") or "").strip()
    if sid:
        delete_session(sid)
    return jsonify({"ok": True})
  
FEEDBACK_LOG = Path("/home/as5289/PYTHON/CHAT/bin/feedback.jsonl")

@app.route("/feedback", methods=["POST"])
def feedback():
    body   = request.get_json()
    rug_id = (body.get("rug_id") or "").strip()
    query  = (body.get("query") or "").strip()
    reason = (body.get("reason") or "not_related").strip()
    if not rug_id:
        return jsonify({"error": "Missing rug_id"}), 400
    entry = {
        "rug_id":    rug_id,
        "query":     query,
        "reason":    reason,
        "timestamp": time.time()
    }
    with open(FEEDBACK_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")
    print(f"Feedback logged: {entry}")
    return jsonify({"ok": True})  

@app.route("/search", methods=["POST"])
def search():
    body        = request.get_json()
    query       = (body.get("query") or "").strip()
    max_results = int(body.get("max_results", 9))
    use_expand  = bool(body.get("expand", False))
    use_rerank  = bool(body.get("rerank", False))
    use_convo   = bool(body.get("convo", False))
    sid         = (body.get("session_id") or "").strip()

    if not query:
        return jsonify({"error": "Empty query"}), 400

    history = []
    if use_convo and sid:
        sess    = load_session(sid)
        history = sess.get("history", [])

    try:
        search_query = expand_query(query) if use_expand else query
        seen_ids     = [rid for h in history for rid in h.get("rug_ids", [])]
        fetch_count  = max_results * 3 if use_rerank else max_results

        with ThreadPoolExecutor(max_workers=1) as executor:
            # fut_summary = executor.submit(rag_summarise, search_query, history if use_convo else None)
            fut_rugs    = executor.submit(retrieve_rugs, search_query, fetch_count, seen_ids)
            # summary     = fut_summary.result()
            rugs        = fut_rugs.result()
        summary = ""

        if use_rerank:
            rugs = rerank_rugs(search_query, rugs)[:max_results]

        if use_convo and sid:
            sess = load_session(sid)
            sess["history"].append({
                "query":   query,
                "count":   len(rugs),
                "rug_ids": [r["rug_id"] for r in rugs]
            })
            save_session(sid, sess)

        return jsonify({
            "rugs":           rugs,
            "summary":        summary,
            "expanded_query": search_query if use_expand else None,
            "reranked":       use_rerank,
            "session_id":     sid if use_convo else None,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ------------------------------------------------------------------ #
#  HTML / CSS / JS
# ------------------------------------------------------------------ #

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pattern Studio</title>
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600&family=Syne:wght@400;600;700&display=swap" rel="stylesheet">
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --bg: #0d0d1a; --glass: rgba(255,255,255,0.04);
  --border: rgba(255,255,255,0.07); --border-hi: rgba(139,92,246,0.4);
  --purple: #8b5cf6; --violet: #7c3aed;
  --text: #e2e8f0; --text-mid: #94a3b8; --text-dim: #475569;
}
body { background: var(--bg); color: var(--text); font-family: 'Plus Jakarta Sans', sans-serif; font-weight: 400; min-height: 100vh; overflow-x: hidden; }
body::before, body::after { content: ''; position: fixed; border-radius: 50%; filter: blur(120px); pointer-events: none; z-index: 0; }
body::before { width: 600px; height: 600px; background: radial-gradient(circle, rgba(139,92,246,0.12) 0%, transparent 70%); top: -100px; left: -100px; }
body::after { width: 500px; height: 500px; background: radial-gradient(circle, rgba(59,130,246,0.08) 0%, transparent 70%); bottom: -100px; right: -100px; }

header { position: sticky; top: 0; z-index: 50; padding: 0 32px; height: 64px; display: flex; align-items: center; gap: 16px; background: rgba(13,13,26,0.8); backdrop-filter: blur(20px); border-bottom: 1px solid var(--border); }
.logo { font-family: 'Syne', sans-serif; font-size: 18px; font-weight: 700; background: linear-gradient(135deg, #a78bfa, #818cf8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
.logo-dot { display: inline-block; width: 7px; height: 7px; background: var(--purple); border-radius: 50%; margin-left: 2px; margin-bottom: 6px; box-shadow: 0 0 8px var(--purple); -webkit-text-fill-color: initial; }
.header-sub { font-size: 11px; letter-spacing: 0.15em; text-transform: uppercase; color: var(--text-dim); padding-left: 16px; border-left: 1px solid var(--border); }
.header-badge { margin-left: auto; font-size: 11px; padding: 4px 12px; border-radius: 20px; background: rgba(139,92,246,0.15); border: 1px solid rgba(139,92,246,0.3); color: #a78bfa; }
.convo-indicator { font-size: 11px; padding: 4px 12px; border-radius: 20px; background: rgba(59,130,246,0.15); border: 1px solid rgba(59,130,246,0.3); color: #93c5fd; display: none; gap: 6px; align-items: center; }
.convo-indicator.active { display: flex; }
.convo-dot { width: 6px; height: 6px; background: #3b82f6; border-radius: 50%; box-shadow: 0 0 6px #3b82f6; animation: pulse 2s infinite; }
@keyframes pulse { 0%,100%{opacity:1;}50%{opacity:0.4;} }

main { position: relative; z-index: 1; max-width: 1280px; margin: 0 auto; padding: 48px 32px 80px; }

.search-panel { background: var(--glass); border: 1px solid var(--border); border-radius: 16px; padding: 32px; backdrop-filter: blur(12px); margin-bottom: 32px; position: relative; overflow: hidden; }
.search-panel::before { content: ''; position: absolute; inset: 0; background: linear-gradient(135deg, rgba(139,92,246,0.06) 0%, transparent 60%); pointer-events: none; }
.search-heading { font-family: 'Syne', sans-serif; font-size: 22px; font-weight: 600; margin-bottom: 6px; background: linear-gradient(90deg, #e2e8f0, #94a3b8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
.search-sub { font-size: 13px; color: var(--text-dim); margin-bottom: 24px; }
.search-row { display: flex; gap: 10px; margin-bottom: 16px; }
#query { flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 10px; padding: 14px 18px; font-family: 'Plus Jakarta Sans', sans-serif; font-size: 14px; font-weight: 300; color: var(--text); outline: none; transition: border-color 0.2s, box-shadow 0.2s; }
#query:focus { border-color: var(--border-hi); box-shadow: 0 0 0 3px rgba(139,92,246,0.1); }
#query::placeholder { color: var(--text-dim); }
#searchBtn { background: linear-gradient(135deg, var(--purple), var(--violet)); color: white; border: none; border-radius: 10px; padding: 0 28px; font-family: 'Plus Jakarta Sans', sans-serif; font-size: 13px; font-weight: 500; cursor: pointer; transition: opacity 0.2s, transform 0.15s; box-shadow: 0 4px 20px rgba(139,92,246,0.3); white-space: nowrap; }
#searchBtn:hover { opacity: 0.9; transform: translateY(-1px); }
#searchBtn:disabled { opacity: 0.4; cursor: default; transform: none; }

.search-options { display: flex; align-items: center; gap: 20px; margin-bottom: 20px; flex-wrap: wrap; }
.toggle-wrap { display: flex; align-items: center; gap: 8px; font-size: 12px; color: var(--text-mid); cursor: pointer; user-select: none; }
.toggle-wrap input[type="checkbox"] { accent-color: var(--purple); width: 14px; height: 14px; cursor: pointer; }
.toggle-wrap select { background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 6px; color: var(--text); font-family: 'Plus Jakarta Sans', sans-serif; font-size: 12px; padding: 4px 8px; outline: none; cursor: pointer; }
.toggle-wrap select:focus { border-color: var(--border-hi); }
.forget-btn { margin-left: auto; font-size: 11px; padding: 5px 14px; border-radius: 20px; background: rgba(239,68,68,0.1); border: 1px solid rgba(239,68,68,0.3); color: #fca5a5; cursor: pointer; display: none; transition: all 0.15s; }
.forget-btn:hover { background: rgba(239,68,68,0.2); }
.forget-btn.visible { display: block; }

.chips-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.chip { font-size: 12px; padding: 6px 14px; border-radius: 20px; background: rgba(255,255,255,0.04); border: 1px solid var(--border); color: var(--text-mid); cursor: pointer; transition: all 0.15s; }
.chip:hover { background: rgba(139,92,246,0.15); border-color: rgba(139,92,246,0.4); color: #a78bfa; }
.refresh-btn { background: none; border: 1px solid var(--border); border-radius: 20px; color: var(--text-dim); font-size: 16px; width: 32px; height: 32px; cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.2s; flex-shrink: 0; }
.refresh-btn:hover { border-color: var(--border-hi); color: #a78bfa; transform: rotate(90deg); }

.summary-bar { display: none; background: var(--glass); border: 1px solid var(--border); border-left: 3px solid var(--purple); border-radius: 12px; padding: 16px 20px; margin-bottom: 24px; backdrop-filter: blur(12px); font-size: 14px; line-height: 1.7; color: var(--text-mid); }
.summary-bar.visible { display: block; }
.summary-meta { font-size: 11px; letter-spacing: 0.15em; text-transform: uppercase; color: var(--purple); margin-bottom: 6px; font-weight: 500; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.badge { font-size: 11px; padding: 3px 10px; background: rgba(139,92,246,0.15); border: 1px solid rgba(139,92,246,0.3); border-radius: 20px; color: #a78bfa; text-transform: none; letter-spacing: 0; }
.badge.blue { background: rgba(59,130,246,0.15); border-color: rgba(59,130,246,0.3); color: #93c5fd; }

.convo-history { margin-bottom: 20px; display: none; }
.convo-history.visible { display: block; }
.convo-history-title { font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--text-dim); margin-bottom: 10px; }
.convo-item { font-size: 12px; color: var(--text-dim); padding: 6px 12px; border-left: 2px solid var(--border); margin-bottom: 6px; }
.convo-item strong { color: var(--text-mid); }

#grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr)); gap: 20px; }
.card { background: var(--glass); border: 1px solid var(--border); border-radius: 14px; overflow: hidden; cursor: pointer; transition: transform 0.25s, border-color 0.25s, box-shadow 0.25s; animation: fadeUp 0.4s ease both; backdrop-filter: blur(12px); }
.card:hover { transform: translateY(-4px); border-color: rgba(139,92,246,0.35); box-shadow: 0 16px 48px rgba(0,0,0,0.4); }
@keyframes fadeUp { from{opacity:0;transform:translateY(20px);}to{opacity:1;transform:translateY(0);} }
.card-img-wrap { width: 100%; aspect-ratio: 4/3; background: #1a1a2e; overflow: hidden; position: relative; display: flex; align-items: center; justify-content: center; }
.card-img { width: 100%; height: 100%; object-fit: contain; image-rendering: auto; filter: blur(0.3px) contrast(1.02); transition: transform 0.35s, filter 0.35s; display: block; }
.card:hover .card-img { transform: scale(1.04); filter: blur(0px) contrast(1.05); }
.card-img-placeholder { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; font-size: 36px; color: var(--text-dim); }
.score-badge { position: absolute; top: 10px; right: 10px; background: rgba(13,13,26,0.75); backdrop-filter: blur(8px); border: 1px solid var(--border); border-radius: 20px; padding: 3px 10px; font-size: 11px; font-weight: 500; color: #a78bfa; }
.flag-btn {
  position: absolute; top: 10px; left: 10px;
  background: rgba(13,13,26,0.75); backdrop-filter: blur(8px);
  border: 1px solid var(--border); border-radius: 20px;
  padding: 3px 10px; font-size: 11px; cursor: pointer;
  color: var(--text-dim); transition: all 0.15s;
}
.flag-btn:hover { background: rgba(239,68,68,0.2); border-color: rgba(239,68,68,0.4); color: #fca5a5; }
.flag-btn.flagged { background: rgba(239,68,68,0.15); border-color: rgba(239,68,68,0.4); color: #fca5a5; }
.card-body { padding: 16px 18px 20px; }
.card-id { font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--text-dim); margin-bottom: 6px; }
.card-style { font-family: 'Syne', sans-serif; font-size: 15px; font-weight: 600; color: var(--text); margin-bottom: 3px; line-height: 1.3; }
.card-pattern { font-size: 12px; color: var(--text-dim); margin-bottom: 14px; line-height: 1.4; }
.color-row { display: flex; flex-wrap: wrap; gap: 5px; margin-bottom: 14px; }
.color-chip { font-size: 10px; padding: 2px 9px; border-radius: 20px; background: rgba(255,255,255,0.05); border: 1px solid var(--border); color: var(--text-mid); }
.card-footer { display: flex; justify-content: space-between; border-top: 1px solid var(--border); padding-top: 12px; font-size: 11px; color: var(--text-dim); }
.card-footer strong { color: var(--text-mid); font-weight: 500; }

#loading { display: none; text-align: center; padding: 60px 0; }
.spinner { width: 40px; height: 40px; margin: 0 auto 20px; border: 2px solid var(--border); border-top-color: var(--purple); border-radius: 50%; animation: spin 0.7s linear infinite; }
@keyframes spin { to{transform:rotate(360deg);} }
#loading p { font-size: 12px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--text-dim); }
#empty { display: none; text-align: center; padding: 80px 0; }
#empty .icon { font-size: 48px; margin-bottom: 20px; }
#empty h2 { font-family: 'Syne', sans-serif; font-size: 22px; font-weight: 600; color: var(--text); margin-bottom: 10px; }
#empty p { font-size: 13px; color: var(--text-dim); line-height: 1.6; }

.modal-bg { display: none; position: fixed; inset: 0; z-index: 100; background: rgba(0,0,0,0.7); backdrop-filter: blur(8px); align-items: center; justify-content: center; padding: 24px; }
.modal-bg.open { display: flex; }
.modal { background: #16162e; border: 1px solid var(--border); border-radius: 20px; max-width: 860px; width: 100%; max-height: 90vh; overflow: hidden; display: grid; grid-template-columns: 1fr 1fr; box-shadow: 0 40px 120px rgba(0,0,0,0.6); animation: modalIn 0.22s ease; }
@keyframes modalIn { from{opacity:0;transform:scale(0.95);}to{opacity:1;transform:scale(1);} }
.modal-img-wrap { background: #0f0f20; display: flex; align-items: center; justify-content: center; min-height: 400px; overflow: hidden; }
.modal-img { width: 100%; height: 100%; object-fit: contain; filter: blur(0.4px) contrast(1.03) saturate(1.08); display: block; }
.modal-img-placeholder { font-size: 72px; color: var(--text-dim); }
.modal-info { padding: 32px; overflow-y: auto; scrollbar-width: thin; scrollbar-color: var(--border) transparent; }
.modal-close { float: right; background: rgba(255,255,255,0.06); border: 1px solid var(--border); border-radius: 8px; width: 32px; height: 32px; display: flex; align-items: center; justify-content: center; cursor: pointer; color: var(--text-mid); font-size: 16px; transition: all 0.15s; margin: -4px -4px 0 0; }
.modal-close:hover { background: rgba(139,92,246,0.2); color: #a78bfa; }
.modal-id { font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--purple); margin-bottom: 10px; }
.modal-title { font-family: 'Syne', sans-serif; font-size: 22px; font-weight: 600; color: var(--text); margin-bottom: 4px; }
.modal-pattern { font-size: 13px; color: var(--text-dim); margin-bottom: 20px; }
.modal-desc { font-size: 13px; line-height: 1.8; color: var(--text-mid); margin-bottom: 24px; padding: 16px; border-radius: 10px; background: rgba(255,255,255,0.03); border: 1px solid var(--border); }
.modal-section { font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--purple); margin: 18px 0 10px; font-weight: 500; }
.tag-list { display: flex; flex-wrap: wrap; gap: 6px; }
.tag { font-size: 11px; padding: 4px 11px; border-radius: 20px; background: rgba(255,255,255,0.04); border: 1px solid var(--border); color: var(--text-mid); }
@media (max-width: 640px) { .modal { grid-template-columns: 1fr; } main { padding: 24px 16px 60px; } header { padding: 0 20px; } }
</style>
</head>
<body>

<header>
  <div class="logo">Pattern Studio<span class="logo-dot"></span></div>
  <div class="header-sub">Rug Design Search</div>
  <div class="convo-indicator" id="convoIndicator">
    <span class="convo-dot"></span><span>Conversation active</span>
  </div>
  <div class="header-badge">AI-Powered</div>
</header>

<main>
  <div class="search-panel">
    <div class="search-heading">Find your pattern</div>
    <div class="search-sub">Describe colours, style, origin, mood — natural language works best</div>
    <div class="search-row">
      <input id="query" type="text" placeholder="e.g. bold tribal geometric in navy and terracotta…" autocomplete="off">
      <button id="searchBtn">Search</button>
    </div>
    <div class="search-options">
      <label class="toggle-wrap">
        <input type="checkbox" id="expandToggle"><span>Query expansion</span>
      </label>
      <label class="toggle-wrap">
        <input type="checkbox" id="rerankToggle"><span>Rerank results</span>
      </label>
      <label class="toggle-wrap">
        <input type="checkbox" id="convoToggle"><span>Conversation mode</span>
      </label>
      <label class="toggle-wrap">
        <span>Results</span>
        <select id="maxResults">
          <option value="9" selected>9</option>
          <option value="18">18</option>
          <option value="27">27</option>
          <option value="36">36</option>
        </select>
      </label>
      <button class="forget-btn" id="forgetBtn" onclick="forgetSession()">✕ Forget session</button>
    </div>
    <div class="chips-row" id="chipsRow">
      <button class="refresh-btn" id="refreshBtn" title="Refresh suggestions">↻</button>
    </div>
  </div>

  <div class="convo-history" id="convoHistory">
    <div class="convo-history-title">Session history</div>
    <div id="convoItems"></div>
  </div>

  <div class="summary-bar" id="summaryBar">
    <div class="summary-meta" id="summaryMeta"></div>
  </div>

  <div id="loading"><div class="spinner"></div><p>Searching pattern library…</p></div>
  <div id="grid"></div>
  <div id="empty">
    <div class="icon">🧵</div>
    <h2>No patterns found</h2>
    <p>Try different terms — colours, styles, origins, or descriptive language all work well.</p>
  </div>
</main>

<div class="modal-bg" id="modalBg" onclick="closeModal(event)">
  <div class="modal">
    <div class="modal-img-wrap" id="modalImgWrap"></div>
    <div class="modal-info" id="modalInfo"></div>
  </div>
</div>

<script>
let currentRugs   = [];
let sessionId     = null;
let sessionHist   = [];
let inactivityTimer = null;

// ---- Session ----
function genSessionId() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random()*16|0;
    return (c==='x'?r:(r&0x3|0x8)).toString(16);
  });
}

function resetInactivityTimer() {
  clearTimeout(inactivityTimer);
  inactivityTimer = setTimeout(() => {
    if (sessionId) {
      fetch('/session/delete', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({session_id:sessionId})});
      sessionId = null; sessionHist = [];
      updateConvoUI();
    }
  }, 5 * 60 * 1000);
}

function forgetSession() {
  if (sessionId) {
    fetch('/session/delete', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({session_id:sessionId})});
    sessionId = null; sessionHist = [];
    updateConvoUI();
  }
}

function updateConvoUI() {
  const on = document.getElementById('convoToggle').checked && !!sessionId;
  document.getElementById('convoIndicator').classList.toggle('active', on);
  document.getElementById('forgetBtn').classList.toggle('visible', !!sessionId);
  const hist  = document.getElementById('convoHistory');
  const items = document.getElementById('convoItems');
  if (sessionHist.length && document.getElementById('convoToggle').checked) {
    hist.classList.add('visible');
    items.innerHTML = sessionHist.map(h =>
      `<div class="convo-item"><strong>"${h.query}"</strong> — ${h.count} results</div>`
    ).join('');
  } else {
    hist.classList.remove('visible');
  }
}

document.getElementById('convoToggle').addEventListener('change', function() {
  if (this.checked) { sessionId = genSessionId(); resetInactivityTimer(); }
  else { forgetSession(); }
  updateConvoUI();
});

// ---- Chips ----
async function refreshChips() {
  const row = document.getElementById('chipsRow');
  row.querySelectorAll('.chip').forEach(c => c.remove());
  const btn = document.getElementById('refreshBtn');
  btn.style.transform = 'rotate(90deg)';
  setTimeout(() => btn.style.transform = '', 300);
  try {
    const res = await fetch('/keywords');
    const kws = await res.json();
    kws.forEach(kw => {
      const chip = document.createElement('span');
      chip.className = 'chip';
      chip.textContent = kw;
      chip.onclick = () => { document.getElementById('query').value = kw; doSearch(); };
      row.insertBefore(chip, btn);
    });
  } catch(e) { console.error(e); }
}

document.getElementById('refreshBtn').addEventListener('click', refreshChips);
refreshChips();

let lastQuery = '';

function flagRug(e, rugId) {
  e.stopPropagation();  // don't open modal
  const btn = document.getElementById('flag-' + rugId);
  if (btn.classList.contains('flagged')) return;
  fetch('/feedback', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({rug_id: rugId, query: lastQuery, reason: 'not_related'})
  }).then(() => {
    btn.classList.add('flagged');
    btn.textContent = '🚩 Flagged';
  }).catch(err => console.error('Flag failed:', err));
}


// ---- Search ----
function doSearch() {
  const query = document.getElementById('query').value.trim();
  if (!query) return;
  lastQuery = query;

  document.getElementById('loading').style.display = 'block';
  document.getElementById('grid').innerHTML = '';
  document.getElementById('empty').style.display = 'none';
  document.getElementById('summaryBar').classList.remove('visible');
  document.getElementById('searchBtn').disabled = true;

  const useConvo = document.getElementById('convoToggle').checked;
  if (useConvo && !sessionId) { sessionId = genSessionId(); }
  if (useConvo) resetInactivityTimer();

  fetch('/search', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({
      query,
      expand:      document.getElementById('expandToggle').checked,
      rerank:      document.getElementById('rerankToggle').checked,
      convo:       useConvo,
      session_id:  sessionId,
      max_results: parseInt(document.getElementById('maxResults').value)
    })
  })
  .then(r => r.json())
  .then(data => {
    document.getElementById('loading').style.display = 'none';
    document.getElementById('searchBtn').disabled = false;

    if (data.error) {
      document.getElementById('summaryText').textContent = 'Error: ' + data.error;
      document.getElementById('summaryBar').classList.add('visible');
      return;
    }

    currentRugs = data.rugs || [];
    let badges = '';
    if (data.expanded_query) badges += `<span class="badge" title="${data.expanded_query}">✦ Expanded</span>`;
    if (data.reranked)        badges += '<span class="badge">⬆ Reranked</span>';
    if (data.session_id)      badges += '<span class="badge blue">💬 Convo</span>';
    document.getElementById('summaryMeta').innerHTML =
      currentRugs.length + ' pattern' + (currentRugs.length!==1?'s':'') + ' retrieved ' + badges;
    document.getElementById('summaryBar').classList.add('visible');

    if (useConvo && data.session_id) {
      sessionHist.push({query, count: currentRugs.length});
      updateConvoUI();
    }

    if (!currentRugs.length) { document.getElementById('empty').style.display='block'; return; }

    const grid = document.getElementById('grid');
    currentRugs.forEach((rug, i) => {
      const card = document.createElement('div');
      card.className = 'card';
      card.style.animationDelay = (i*0.055)+'s';
      card.onclick = () => openModal(i);
      const imgHtml = rug.img_url
        ? `<img class="card-img" src="${rug.img_url}" alt="Rug ${rug.rug_id}" loading="lazy" onerror="this.style.display='none';this.parentNode.innerHTML='<div class=card-img-placeholder>🔲</div>'">`
        : `<div class="card-img-placeholder">🔲</div>`;
      const colors = (rug.primary_colors||[]).slice(0,4).map(c=>`<span class="color-chip">${c}</span>`).join('');
      card.innerHTML = `
        <div class="card-img-wrap">
          ${imgHtml}
          <span class="score-badge">${rug.score}%</span>
          <button class="flag-btn" id="flag-${rug.rug_id}" onclick="flagRug(event,'${rug.rug_id}')">🚩</button>
        </div>
        <div class="card-body">
          <div class="card-id">ID ${rug.rug_id} &nbsp;·&nbsp; ${rug.width}′ × ${rug.height}′</div>
          <div class="card-style">${rug.style}</div>
          <div class="card-pattern">${rug.pattern_type}</div>
          <div class="color-row">${colors}</div>
          <div class="card-footer">
            <span><strong>${rug.origin}</strong> origin</span>
            <span><strong>${rug.material}</strong></span>
          </div>
        </div>`;
      grid.appendChild(card);
    });
  })
  .catch(err => {
    document.getElementById('loading').style.display = 'none';
    document.getElementById('searchBtn').disabled = false;
    document.getElementById('summaryText').textContent = 'Request failed: ' + err;
    document.getElementById('summaryBar').classList.add('visible');
  });
}

function openModal(i) {
  const rug = currentRugs[i]; if (!rug) return;
  const imgHtml = rug.img_url
    ? `<img class="modal-img" src="${rug.img_url}" alt="Rug ${rug.rug_id}" onerror="this.parentNode.innerHTML='<div class=modal-img-placeholder>🔲</div>'">`
    : `<div class="modal-img-placeholder">🔲</div>`;
  document.getElementById('modalImgWrap').innerHTML = imgHtml;
  const allColors = [...(rug.primary_colors||[]),...(rug.secondary_colors||[])].map(c=>`<span class="tag">${c}</span>`).join('');
  const elements  = (rug.design_elements||[]).map(e=>`<span class="tag">${e}</span>`).join('');
  document.getElementById('modalInfo').innerHTML = `
    <button class="modal-close" onclick="document.getElementById('modalBg').classList.remove('open')">✕</button>
    <div class="modal-id">Pattern ${rug.rug_id} &nbsp;·&nbsp; ${rug.width}′ × ${rug.height}′ &nbsp;·&nbsp; ${rug.score}% match</div>
    <div class="modal-title">${rug.style}</div>
    <div class="modal-pattern">${rug.pattern_type}</div>
    <div class="modal-desc">${rug.description}</div>
    <div class="modal-section">Colours</div><div class="tag-list">${allColors}</div>
    <div class="modal-section">Design Elements</div><div class="tag-list">${elements}</div>
    <div class="modal-section">Details</div>
    <div class="tag-list">
      <span class="tag">Origin: ${rug.origin}</span>
      <span class="tag">Material: ${rug.material}</span>
      <span class="tag">Tone: ${rug.tone}</span>
      <span class="tag">Complexity: ${rug.complexity}</span>
    </div>`;
  document.getElementById('modalBg').classList.add('open');
}

function closeModal(e) {
  if (!e || e.target===document.getElementById('modalBg'))
    document.getElementById('modalBg').classList.remove('open');
}

document.getElementById('query').addEventListener('keydown', e => { if(e.key==='Enter') doSearch(); });
document.getElementById('searchBtn').addEventListener('click', doSearch);
document.addEventListener('keydown', e => { if(e.key==='Escape') document.getElementById('modalBg').classList.remove('open'); });
</script>
</body>
</html>"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
