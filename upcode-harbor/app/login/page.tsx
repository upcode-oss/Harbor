"use client"
import { useState, useEffect, useRef } from "react"
import { useRouter } from "next/navigation"
import Image from "next/image"
import { useAuth } from "@/components/auth-provider"
import { apiUrl } from "@/lib/api"

interface CustomizationData {
  banner_title: string
  banner_subtitle: string
  has_logo: boolean
  has_banner: boolean
}

const DEFAULT_CUSTOMIZATION: CustomizationData = {
  banner_title: "Welcome to Upcode Harbor",
  banner_subtitle: "Professional Server Management Platform",
  has_logo: false,
  has_banner: false,
}

export default function LoginPage() {
  const [username, setUsername] = useState("")
  const [password, setPassword] = useState("")
  const [error, setError] = useState("")
  const [customization, setCustomization] = useState<CustomizationData>(DEFAULT_CUSTOMIZATION)

  // 2FA state
  const [step, setStep] = useState<"credentials" | "totp">("credentials")
  const [loginToken, setLoginToken] = useState("")
  const [totpCode, setTotpCode] = useState("")
  const [totpLoading, setTotpLoading] = useState(false)
  const totpInputRef = useRef<HTMLInputElement>(null)

  const { setToken } = useAuth()
  const router = useRouter()

  useEffect(() => {
    const fetchCustomization = async () => {
      try {
        const res = await fetch(apiUrl("/settings/customization"))
        if (res.ok) {
          const data = await res.json()
          setCustomization({ ...DEFAULT_CUSTOMIZATION, ...data })
        }
      } catch {
        // silently fall back to defaults
      }
    }
    fetchCustomization()
  }, [])

  // Auto-focus TOTP input when switching to the 2FA step
  useEffect(() => {
    if (step === "totp") {
      setTimeout(() => totpInputRef.current?.focus(), 50)
    }
  }, [step])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError("")
    try {
      const res = await fetch(apiUrl("/auth/login"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ username, password }),
      })
      if (res.ok) {
        const data = await res.json()
        if (data["2fa_required"]) {
          setLoginToken(data.login_token)
          setStep("totp")
        } else {
          await setToken("session")
          router.push("/")
        }
      } else {
        setError("Invalid username or password")
      }
    } catch {
      setError("Login failed")
    }
  }

  const handleTotpSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError("")
    if (!totpCode.trim()) return
    setTotpLoading(true)
    try {
      const res = await fetch(apiUrl("/auth/2fa/complete"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ login_token: loginToken, code: totpCode.trim() }),
      })
      if (res.ok) {
        await setToken("session")
        router.push("/")
      } else {
        setError("Invalid or expired 2FA code. Please try again.")
        setTotpCode("")
        totpInputRef.current?.focus()
      }
    } catch {
      setError("Login failed")
    } finally {
      setTotpLoading(false)
    }
  }

  const handleTotpChange = (val: string) => {
    const digits = val.replace(/\D/g, "").slice(0, 6)
    setTotpCode(digits)
    setError("")
  }

  return (
    <div className="flex min-h-screen bg-gradient-to-br from-slate-50 via-blue-50 to-indigo-100 dark:from-slate-900 dark:via-slate-800 dark:to-indigo-900">
      <div className="relative w-1/2 overflow-hidden">
        <div className="absolute inset-0 bg-gradient-to-br from-primary/20 to-purple-600/20 z-10"></div>
        {customization.has_banner ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={apiUrl("/settings/customization/banner/file")}
            alt="Login banner"
            className="absolute inset-0 w-full h-full object-cover"
          />
        ) : (
          <Image
            src="/login.jpg"
            alt="Login illustration"
            fill
            sizes="50vw"
            className="object-cover"
          />
        )}
        <div className="absolute inset-0 z-20 flex items-center justify-center">
          <div className="text-center text-white p-8">
            <div className="flex items-center justify-center mx-auto mb-6">
              {customization.has_logo ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={apiUrl("/settings/customization/logo/file")}
                  alt="Logo"
                  className="h-48 w-auto max-w-full object-contain"
                />
              ) : (
                // eslint-disable-next-line @next/next/no-img-element
                <img src="/logo.png" alt="Upcode Harbor Logo" className="h-48 w-auto max-w-full object-contain" />
              )}
            </div>
            <h1 className="text-4xl font-bold mb-4">{customization.banner_title}</h1>
            <p className="text-xl opacity-90">{customization.banner_subtitle}</p>
          </div>
        </div>
      </div>
      <div className="flex w-1/2 items-center justify-center p-8">
        <div className="w-full max-w-md">
          <div className="upcode-harbor-card p-8 space-y-6">

            {step === "credentials" && (
              <>
                <div className="text-center mb-8">
                  <h2 className="text-3xl font-bold text-white mb-2">Sign In</h2>
                  <p className="text-muted-foreground">Sign in with an existing Linux account</p>
                </div>
                <form onSubmit={handleSubmit} className="space-y-6">
                  <div className="space-y-2">
                    <label className="text-sm font-semibold text-foreground">Username</label>
                    <input
                      className="w-full h-12 px-4 border border-border/50 bg-background/80 backdrop-blur-sm focus:border-primary/60 focus:ring-2 focus:ring-primary/20 focus:outline-none transition-all duration-200"
                      value={username}
                      onChange={(e) => setUsername(e.target.value)}
                      placeholder="Linux username"
                      autoComplete="username"
                    />
                  </div>
                  <div className="space-y-2">
                    <label className="text-sm font-semibold text-foreground">Password</label>
                    <input
                      type="password"
                      className="w-full h-12 px-4 border border-border/50 bg-background/80 backdrop-blur-sm focus:border-primary/60 focus:ring-2 focus:ring-primary/20 focus:outline-none transition-all duration-200"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      placeholder="Enter your password"
                      autoComplete="current-password"
                    />
                  </div>
                  {error && (
                    <div className="p-3 rounded-lg bg-destructive/10 border border-destructive/20">
                      <p className="text-destructive text-sm font-medium">{error}</p>
                    </div>
                  )}
                  <button
                    type="submit"
                    className="w-full upcode-harbor-button-primary text-white font-semibold py-3 px-4 shadow-lg hover:shadow-xl transform hover:-translate-y-1 transition-all duration-300"
                  >
                    Sign In
                  </button>
                </form>
              </>
            )}

            {step === "totp" && (
              <>
                <div className="text-center mb-8">
                  <div className="flex items-center justify-center w-16 h-16 rounded-full bg-primary/20 mx-auto mb-4">
                    <svg className="w-8 h-8 text-primary" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
                    </svg>
                  </div>
                  <h2 className="text-2xl font-bold text-white mb-2">Two-Factor Authentication</h2>
                  <p className="text-muted-foreground text-sm">
                    Enter the 6-digit code from your authenticator app
                  </p>
                </div>
                <form onSubmit={handleTotpSubmit} className="space-y-6">
                  <div className="space-y-2">
                    <label className="text-sm font-semibold text-foreground">Authentication Code</label>
                    <input
                      ref={totpInputRef}
                      type="text"
                      inputMode="numeric"
                      pattern="[0-9]*"
                      maxLength={6}
                      className="w-full h-14 px-4 text-center text-2xl tracking-[0.5em] font-mono border border-border/50 bg-background/80 backdrop-blur-sm focus:border-primary/60 focus:ring-2 focus:ring-primary/20 focus:outline-none transition-all duration-200"
                      value={totpCode}
                      onChange={(e) => handleTotpChange(e.target.value)}
                      placeholder="000000"
                      autoComplete="one-time-code"
                    />
                  </div>
                  {error && (
                    <div className="p-3 rounded-lg bg-destructive/10 border border-destructive/20">
                      <p className="text-destructive text-sm font-medium">{error}</p>
                    </div>
                  )}
                  <button
                    type="submit"
                    disabled={totpLoading || totpCode.length !== 6}
                    className="w-full upcode-harbor-button-primary text-white font-semibold py-3 px-4 shadow-lg hover:shadow-xl transform hover:-translate-y-1 transition-all duration-300 disabled:opacity-50 disabled:cursor-not-allowed disabled:transform-none"
                  >
                    {totpLoading ? "Verifying..." : "Verify"}
                  </button>
                  <button
                    type="button"
                    className="w-full text-sm text-muted-foreground hover:text-foreground transition-colors"
                    onClick={() => { setStep("credentials"); setError(""); setTotpCode(""); setLoginToken("") }}
                  >
                    ← Back to login
                  </button>
                </form>
              </>
            )}

          </div>
        </div>
      </div>
    </div>
  )
}
