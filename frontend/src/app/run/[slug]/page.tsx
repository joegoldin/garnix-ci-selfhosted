"use client";

import { useCallback } from "react";
import React from "react";
import { P, match } from "ts-pattern";
import { Text } from "@/components/text";
import { useLoading } from "@/hooks/useLoading";
import { fromSecs } from "@/utils/duration";
import { Err, Ok } from "@/services";
import { getRun } from "@/services/run";
import { RunPage } from "@/components/run";

const Page = ({ params }: { params: { slug: string } }) => {
  const run = useLoading(
    useCallback(() => getRun(params.slug), [params.slug]),
    {
      poll: fromSecs(5),
      shouldPoll: (result) =>
        match(result)
          .with(Err(P._), () => true)
          .with(Ok({ status: "Pending" }), () => true)
          .with(Ok({ status: "Running" }), () => true)
          .with(Ok(P._), () => false)
          .exhaustive(),
    },
  );
  if (run.loading) return null;
  return match(run.data)
    .with(Ok(P.select()), (data) => (
      <RunPage run={data} onChanged={run.reload} />
    ))
    .with(Err(P._), () => (
      <Text>
        Uh oh! No run matching that description could be found. Either it
        doesn&apos;t exist, or you don&apos;t have access to it.
      </Text>
    ))
    .exhaustive();
};

export default Page;
