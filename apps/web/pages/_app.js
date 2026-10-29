import '~/styles/style.scss'
import React, { useState, useEffect } from 'react'
import Head from 'next/head'
import { useRouter } from 'next/router'
import { SITE_NAME } from '~/lib/site'
import UserContext from 'lib/UserContext'
import { supabase } from 'lib/Store'
import { jwtDecode } from 'jwt-decode'

// Upstream names this component after the example itself; it is ChatApp
// here because that name spells this repository's own slug, which a product
// built from it must not carry.
export default function ChatApp({ Component, pageProps }) {
  const [userLoaded, setUserLoaded] = useState(false)
  const [user, setUser] = useState(null)
  const [session, setSession] = useState(null)
  const router = useRouter()

  useEffect(() => {
    function saveSession(
      /** @type {Awaited<ReturnType<typeof supabase.auth.getSession>>['data']['session']} */
      session
    ) {
      setSession(session)
      const currentUser = session?.user
      if (session) {
        const jwt = jwtDecode(session.access_token)
        currentUser.appRole = jwt.user_role
      }
      setUser(currentUser ?? null)
      setUserLoaded(!!currentUser)
      if (currentUser) {
        router.push('/channels/[id]', '/channels/1')
      }
    }

    supabase.auth.getSession().then(({ data: { session } }) => saveSession(session))

    const {
      data: { subscription: authListener },
    } = supabase.auth.onAuthStateChange(
      async (event, session) => {
        console.log(session)
        saveSession(session)
      }
    )

    return () => {
      authListener.unsubscribe()
    }
  }, [])

  const signOut = async () => {
    const { error } = await supabase.auth.signOut()
    if (!error) {
      router.push('/')
    }
  }

  return (
    <UserContext.Provider
      value={{
        userLoaded,
        user,
        signOut,
      }}
    >
      <Head>
        <title>{SITE_NAME}</title>
      </Head>
      <Component {...pageProps} />
    </UserContext.Provider>
  )
}
