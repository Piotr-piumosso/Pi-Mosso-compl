# Wdrożenie Cloudflare Worker — formularz kontaktowy

## Co to robi
Formularz na stronie POSTuje do tego Workera.
Worker wywołuje GitHub Actions w `piumosso-engine`, które zapisuje lead do `data/inbound_leads.csv`.

## Jednorazowe wdrożenie (5 minut)

### 1. Utwórz konto Cloudflare
https://dash.cloudflare.com/sign-up — bezpłatne, bez karty.

### 2. Utwórz Worker
- Zaloguj się → Workers & Pages → Create application → Create Worker
- Nazwa: `form-handler`
- Kliknij „Deploy"

### 3. Wklej kod
- Kliknij „Edit code"
- Zaznacz wszystko i usuń
- Wklej zawartość pliku `workers/form-handler.js` z tego repo
- Kliknij „Save and deploy"

### 4. Dodaj sekrety (Variables)
- W Workerze: Settings → Variables → Add variable (type: Secret)
- `GH_PAT` — Twój GitHub Personal Access Token
  - Utwórz na: https://github.com/settings/tokens → Generate new token (classic)
  - Scopes: `repo` (pełny repo access)
- `ALLOWED_ORIGIN` — `https://piumosso.pl`

### 5. Skopiuj URL Workera
- Będzie coś w stylu: `https://form-handler.piotr-piumosso.workers.dev`
- W pliku `index.html` znajdź linię:
  ```js
  const FORM_WORKER_URL = "https://form-handler.piotr-piumosso.workers.dev";
  ```
- Podmień na swój URL jeśli inny, zapisz i pushuj

---

## Tracking Worker (otwarcia emaili) — opcjonalny

### 1. Utwórz drugi Worker
- Workers & Pages → Create Worker → nazwa: `track-handler`
- Wklej zawartość `workers/track-handler.js`
- Kliknij „Save and deploy"

### 2. Utwórz KV Namespace
- Workers & Pages → KV → Create namespace → nazwa: `OPENS_KV`
- W ustawieniach Workera `track-handler` → Bindings → Add → KV Namespace
  - Variable name: `OPENS_KV`
  - KV namespace: wybierz `OPENS_KV`

### 3. Dodaj sekrety do tracking Workera
- `STATS_TOKEN` — dowolne hasło, np. 32-znakowy losowy string

### 4. Ustaw zmienne w piumosso-engine (GitHub → Settings → Variables)
- `TRACK_WORKER_URL` = `https://track-handler.piotr-piumosso.workers.dev`

### 5. Dodaj sekret w piumosso-engine (GitHub → Settings → Secrets)
- `TRACK_STATS_TOKEN` = ten sam token co w punkcie 3

---

## Po wdrożeniu
- Każde wypełnienie formularza → wpis w `piumosso-engine/data/inbound_leads.csv`
- Commit w repo z imieniem i nazwiskiem klienta
- Strona pokazuje komunikat „Wiadomość wysłana." bez przekierowania

## Fallback
Jeśli Worker nie odpowie (np. błąd sieciowy), formularz automatycznie otwiera klienta pocztowego — żadna wiadomość nie przepadnie.
