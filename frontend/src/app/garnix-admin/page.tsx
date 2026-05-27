"use client";

import dynamic from "next/dynamic";
import { z } from "zod";
import { P, match } from "ts-pattern";
import { useState } from "react";
import { Err, Ok, fetchFromAPI } from "@/services";
import { useLoading } from "@/hooks/useLoading";
import { Button } from "@/components/button";
import styles from "./styles.module.css";

const CreateGithubApp = dynamic(() => import("./createGithubApp"), {
  ssr: false,
});

const userSchema = z
  .object({
    username: z.string(),
    email: z.string(),
    is_admin: z.boolean(),
  })
  .nullable();

const getWhoami = () => fetchFromAPI(userSchema, "GET", "whoami");

const Page = () => {
  const [error, setError] = useState<string | null>(null);
  const loadingUser = useLoading(getWhoami);
  if (loadingUser.loading) return null;
  return (
    <div className={`${styles.body}`}>
      <h1>Admin Page</h1> (<a href="..">back to the main site</a>)
      <hr />
      {error && (
        <>
          {error}
          <hr />
        </>
      )}
      {match(loadingUser.data)
        .with(Err(P.select()), (error) => <>Error: {error.message}</>)
        .with(Ok(P.select()), (user) => {
          if (user == null)
            return (
              <>
                Not logged in.
                <Button
                  onClick={() =>
                    devLogMeIn({ setError, reload: loadingUser.reload })
                  }
                >
                  Log in as admin dev user
                </Button>
              </>
            );
          if (!user.is_admin) return <>User {user.username} is not an admin!</>;
          return <CreateGithubApp setError={setError} />;
        })
        .exhaustive()}
      <hr />
    </div>
  );
};

const devLogMeIn = async (props: {
  setError: (msg: string) => void;
  reload: () => void;
}) => {
  const result = await fetchFromAPI(
    z.object({ success: z.literal(true) }),
    "GET",
    "dev/log-me-in",
  );
  if (!result.ok) props.setError(result.error.message);
  props.reload();
};

export default Page;
