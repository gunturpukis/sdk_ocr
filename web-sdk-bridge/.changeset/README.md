# Changesets

Alat versioning + changelog untuk `@gunturpukis/ocr-scanner-react`.

## Alur sehari-hari

```bash
cd web-sdk-bridge
npx changeset            # buat file changeset baru (pilih bump: patch/minor/major)
                         # commit file .md hasilnya bersama PR Anda
```

Setelah beberapa changeset terkumpul di `main`:

```bash
npx changeset version    # konsumsi changeset → bump package.json + tulis CHANGELOG.md
git commit -am "chore: version packages" && git push
git tag v$(node -p "require('./package.json').version") && git push --tags
```

Push tag `v*` memicu `.github/workflows/release.yml` → build + publish ke npm
(dengan provenance) secara otomatis.

## Catatan

- Konfigurasi ada di `.changeset/config.json` (access public, baseBranch main).
- `CHANGELOG.md` ditulis otomatis oleh `changeset version`.
- First publish tetap manual dari mesin Anda (butuh OTP 2FA) — lihat
  README bagian Publishing.
