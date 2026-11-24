# DayForge

Build Your Day. Become Your Best.

## Structure
- `www/index.html`: approved prototype (data in local storage only for now)
- `supabase/migrations/001_core.sql`: database schema with row-level security
- `capacitor.config.json`, `package.json`: Android wrapper setup
- `.github/workflows/android-debug.yml`: builds a debug APK on GitHub
- `.env.example`: which values are public and which are server-only secrets

## Get a debug APK without Android Studio
1. Create a GitHub repository and push this folder to the `main` branch.
2. Open the repo's **Actions** tab, then **Build debug APK**, then **Run workflow** (it also runs on every push).
3. When it finishes, open the run and download `dayforge-debug-apk` from **Artifacts**. Unzip it.
4. Copy `app-debug.apk` to your phone and install it (allow "install unknown apps" when asked).

The first run may need small fixes; send me the error log if it fails.

## Database
Run `supabase/migrations/001_core.sql` in the Supabase SQL Editor, then:
`insert into app_config values ('owner_email','YOUR_VERIFIED_EMAIL');`

## Status
Done: prototype UI, database schema, APK build workflow (untested).
Not done: Supabase login in the app, Razorpay and coupon Edge Functions, push and local notifications in the app, release signing.

## Security
Never commit `.env`, keystores, the Razorpay Key Secret, the webhook secret or the Supabase service-role key.
