
/**
 * Initialization pre-processing hook.
 *
 * @return int - error status
 */
int onInit() {
   SNOWROLLER = false;                                   // MQL4 doesn't allow constant bool definitions
   SISYPHUS   = true;
   return(NO_ERROR);
}
