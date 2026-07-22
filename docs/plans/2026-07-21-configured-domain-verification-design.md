# Configured domain verification

## Goal

Make every domain on Configure → Connected domains show durable verification
status. Show Verify only while a domain is unverified. Nix-configured wildcard
bases remain read-only; manually registered domains remain deletable.

## Current problem

Manually registered domains live in `connected_domains`, so the API can return
their persisted `verified_at` state. The default hosting domain and
`extraHostingDomains` reach the frontend separately through `hostingBases` and
have no database identity or verification state. The frontend therefore labels
them only as `nix-configured`. It also renders Verify unconditionally for
manually registered domains, including verified ones.

## Persistence model

Add a dedicated table keyed by configured domain name with a nullable
`verified_at` timestamp. This table stores verification state only. It does not
participate in routing or ownership decisions.

Keeping this state separate from `connected_domains` preserves two important
boundaries:

- Removing a base from Nix configuration cannot leave behind a verified,
  routable connected domain.
- A Nix-configured base cannot become deletable or editable through the
  connected-domain API.

Rows for bases no longer present in Nix may remain dormant; they have no effect
unless the same base is configured again, at which point its prior verification
state is reused.

## API behavior

The domain-list response becomes a unified list containing both configured and
manually registered domains. Each item includes:

- domain name;
- wildcard status;
- persisted verification status;
- whether it is Nix-configured;
- a database id only for manually registered domains.

Configured bases are the backend's `hostingDomain` plus
`extraHostingDomains`, not the frontend's broader `hostingBases` list. This
prevents verified connected domains from being misclassified as configured.
Duplicate names are returned once, with Nix-configured/read-only semantics
taking precedence.

The existing id-based verification endpoint remains for manually registered
domains. Add a configured-domain verification endpoint accepting a domain
name. Before any DNS lookup or write, it must verify that the requested name is
currently in the configured-base set. Successful DNS-points-here verification
sets `verified_at`; a failed retry never clears a previous success, matching the
existing connected-domain behavior.

All list and mutation routes remain self-host-only and admin-only.

## Frontend behavior

Render the unified API list directly:

- Every row shows `resolves here` or `not verified`.
- Verify is rendered only when `verified` is false.
- Nix-configured rows show `wildcard base` and `nix-configured`, with no Delete.
- Manually registered rows retain Delete.
- Clicking Verify calls the appropriate configured-name or connected-id route,
  then reloads the list. A successful reload removes the button.

The explanatory text continues to distinguish read-only configured bases from
domains registered through the form.

## Failure behavior

Failed DNS resolution leaves the row unverified and keeps Verify available.
Unknown or no-longer-configured names are rejected without a DNS lookup or
database write. API failures use the page's existing error/loading behavior;
they do not optimistically mark a row verified.

## Verification

Focused backend tests cover configured-domain listing, persistence after a
successful check, rejection of unconfigured names, duplicate suppression, and
the unchanged manual-domain path. A focused frontend test covers status for
both row types, hidden Verify buttons for verified rows, Verify on unverified
rows, and Delete only for manually registered domains.

Only the affected backend Configure spec and frontend Configure-page test are
run while iterating. The SQL migration and API JSON contract are included in
the final focused verification.
