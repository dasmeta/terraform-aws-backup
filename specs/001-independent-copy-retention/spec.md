# Independent retention and archive tiers

Keep existing backup defaults. Allow source and destination copies to use different retention periods, and offer optional periodic snapshot tiers for explicit resources, reusing the module's vaults and selection role.

Provide a reusable two-stage RDS copy submodule with optional archive tiers, preserving recovery-point lifecycles when forwarding. Consumers supply account-specific provider configurations and role and vault settings.
