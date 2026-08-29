/// Shared geometry for Planner-local Event and Task editor sheets.
///
/// Both editors begin at their content-measured partial extent, while this
/// shared maximum reaches the full safe-area height.  Keeping the limit here
/// prevents the two production creation paths from drifting apart.
const double kPlannerEditorSheetMaxChildSize = 1.0;
