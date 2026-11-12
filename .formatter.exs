# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

spark_locals_without_parens = [
  action: 1,
  argument_names: 1,
  base: 1,
  delete: 1,
  delete: 2,
  description: 1,
  enable_filter?: 1,
  enable_sort?: 1,
  error_handler: 1,
  field_names: 1,
  get: 1,
  get: 2,
  include_nil_values?: 1,
  includes: 1,
  index: 1,
  index: 2,
  metadata: 1,
  method: 1,
  modify_conn: 1,
  name: 1,
  paginate?: 1,
  patch: 1,
  patch: 2,
  post: 1,
  post: 2,
  primary?: 1,
  query_params: 1,
  read_action: 1,
  related: 2,
  related: 3,
  relationship: 1,
  route: 1,
  route: 3,
  route: 4,
  show_raised_errors?: 1,
  type: 1,
  wrap_in_result?: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,dev}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens],
  import_deps: [:ash, :spark, :plug]
]
