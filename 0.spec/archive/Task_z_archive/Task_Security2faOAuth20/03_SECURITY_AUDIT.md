# Security Audit Checklist
## Pre and Post Implementation Verification

---

# Pre-Implementation Audit

Run these tests BEFORE implementing OAuth2 Proxy to document current vulnerabilities.

## Network Exposure Tests

```bash
# Test 1: Matomo public port
curl -I http://<OCI_PUBLIC_IP>:8080
# Expected: HTTP 200 (VULNERABLE)
# Result: _______________

# Test 2: External port scan
nmap -p 22,80,443,8080,2283,2342 <OCI_PUBLIC_IP>
# Expected: Multiple open ports
# Result: _______________

# Test 3: SSH access
ssh -o ConnectTimeout=5 ubuntu@<OCI_PUBLIC_IP>
# Expected: Password/key prompt (should be WireGuard only)
# Result: _______________
```

## Authentication Tests

```bash
# Test 4: Matomo login page
curl -s https://analytics.diegonmarcos.com | grep -i "login"
# Expected: Native login form visible
# Result: _______________

# Test 5: Mailu webmail login
curl -s https://mail.diegonmarcos.com | grep -i "login"
# Expected: Native login form visible
# Result: _______________

# Test 6: 2FA check
# Try logging in - is 2FA required?
# Expected: NO (VULNERABLE)
# Result: _______________
```

## Current Risk Score

| Vulnerability | Present? | Severity |
|--------------|----------|----------|
| Port 8080 public | [ ] Yes / [ ] No | High |
| No 2FA on web apps | [ ] Yes / [ ] No | Critical |
| Native logins enabled | [ ] Yes / [ ] No | Medium |
| SSH port 22 public | [ ] Yes / [ ] No | Medium |

**Pre-Implementation Risk Level: ___/100**

---

# Post-Implementation Audit

Run these tests AFTER implementing OAuth2 Proxy to verify security improvements.

## Network Exposure Tests

```bash
# Test 1: Matomo direct access blocked
curl -I http://<OCI_PUBLIC_IP>:8080
# Expected: Connection refused/timeout
# Result: _______________
# Pass: [ ] Yes / [ ] No

# Test 2: Port scan
nmap -p 8080,2283,2342 <OCI_PUBLIC_IP>
# Expected: All filtered/closed
# Result: _______________
# Pass: [ ] Yes / [ ] No

# Test 3: Only HTTPS works
curl -I http://analytics.diegonmarcos.com
# Expected: Redirect to HTTPS
# Result: _______________
# Pass: [ ] Yes / [ ] No
```

## OAuth Flow Tests

```bash
# Test 4: OAuth redirect
curl -sI https://analytics.diegonmarcos.com | grep -i location
# Expected: Redirect to GitHub or /oauth2/sign_in
# Result: _______________
# Pass: [ ] Yes / [ ] No

# Test 5: Auth endpoint accessible
curl -sI https://auth.diegonmarcos.com/ping
# Expected: HTTP 200
# Result: _______________
# Pass: [ ] Yes / [ ] No
```

## Manual Browser Tests

```
Test 6: Full OAuth Flow
1. Open incognito browser
2. Go to https://analytics.diegonmarcos.com
3. Verify redirect to GitHub
4. Login with GitHub (should require 2FA)
5. Verify redirect back to Matomo
6. Verify logged in as correct user

Expected: All steps complete successfully
Result: _______________
Pass: [ ] Yes / [ ] No
```

```
Test 7: Unauthorized User Blocked
1. Login with different GitHub account (not in allowed list)
2. Try accessing https://analytics.diegonmarcos.com

Expected: "Forbidden" or "Unauthorized" error
Result: _______________
Pass: [ ] Yes / [ ] No
```

```
Test 8: Session Cookie Security
1. Open browser dev tools → Application → Cookies
2. Check _oauth2_proxy cookie

Expected attributes:
- Secure: Yes
- HttpOnly: Yes
- SameSite: Lax or Strict

Result: _______________
Pass: [ ] Yes / [ ] No
```

## Cross-App Authentication

```
Test 9: SSO across apps
1. Login to https://analytics.diegonmarcos.com
2. Navigate to https://mail.diegonmarcos.com
3. Should NOT require re-authentication

Expected: Same session works across subdomains
Result: _______________
Pass: [ ] Yes / [ ] No
```

## Native Login Bypass Prevention

```
Test 10: Native login still works (but behind OAuth)
1. After OAuth login, try Matomo native login
2. Should reach Matomo with OAuth headers

Expected: OAuth provides access, native login optional
Result: _______________
Pass: [ ] Yes / [ ] No
```

---

# Security Comparison

| Metric | Before | After | Improved? |
|--------|--------|-------|-----------|
| Public ports | ___ | ___ | [ ] |
| 2FA enabled | No | Yes | [ ] |
| Centralized auth | No | Yes | [ ] |
| Session management | None | Cookie-based | [ ] |
| Audit trail | None | OAuth logs | [ ] |

---

# Final Risk Assessment

## Post-Implementation Risk Score

| Vulnerability | Present? | Severity |
|--------------|----------|----------|
| Port 8080 public | [ ] Yes / [ ] No | - |
| No 2FA on web apps | [ ] Yes / [ ] No | - |
| Native logins only auth | [ ] Yes / [ ] No | - |
| Unauthorized access possible | [ ] Yes / [ ] No | - |

**Post-Implementation Risk Level: ___/100**

## Risk Reduction

```
Before: ___/100
After:  ___/100
Reduction: ___%
```

---

# Known Limitations

After implementation, these remain:

1. **Email ports (25, 587, 993)** - Required for email delivery, acceptable risk
2. **Native app logins** - Still exist but only accessible after OAuth
3. **Device trust** - Basic (email allowlist only), not full device posture
4. **GitHub dependency** - If GitHub OAuth is down, no access

---

# Incident Response

## If OAuth2 Proxy fails:

```bash
# Check status
docker logs oauth2-proxy

# Restart
cd ~/oauth2-proxy && docker-compose restart

# Emergency bypass (temporary)
# In NPM, remove advanced config from proxy hosts
# Apps revert to direct access (no auth)
```

## If locked out:

```bash
# Access via WireGuard + SSH
wg-quick up wg0
ssh diego@10.0.0.1

# Check OAuth2 Proxy
docker logs oauth2-proxy

# Verify allowed_emails.txt has your email
cat ~/oauth2-proxy/config/allowed_emails.txt
```

---

# Sign-Off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Implementer | | | |
| Reviewer | | | |

**Implementation Complete: [ ] Yes / [ ] No**
**All Tests Passed: [ ] Yes / [ ] No**
**Risk Acceptable: [ ] Yes / [ ] No**
