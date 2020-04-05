/**
 * Constants shared by framework (MQL) and MT4Expander (C++)
 */


// special constants
#define EMPTY                    0xFFFFFFFF              // -1
#define NaC                      0xFFFFFFFE              // Not-a-Color: invalid color value (-2)
#define NaT                      0x80000000              // Not-a-Time: invalid datetime value (INT_MIN)
#define MIN_VALID_POINTER        0x00010000              // minimum value of a valid 32 bit pointer (x86)
#define MAX_ORDER_COMMENT_LENGTH         27
#define MAX_SYMBOL_GROUP_LENGTH          15
#define MAX_SYMBOL_LENGTH                11

#define NL                             "\n"              // new line: 0x0A (MQL file functions auto-convert 0x0A to 0x0D0A)
#define TAB                            "\t"              // tab: 0x09


// log level
#define L_OFF                    0x80000000              // same as INT_MIN which in C++ is internally defined
#define L_FATAL                       10000              //
#define L_ERROR                       20000              // logic opposite to log4j: if (__LOG_LEVEL >= msg_level) log  (...);
#define L_WARN                        30000              // or more simple:          if (__LOG_DEBUG)              debug(...);
#define L_INFO                        40000              //
#define L_NOTICE                      50000              //
#define L_DEBUG                       60000              //
#define L_ALL                    0x7FFFFFFF              // same as INT_MAX which in C++ is internally defined


// MQL module type flags
#define MODULETYPE_INDICATOR              1
#define MODULETYPE_EXPERT                 2
#define MODULETYPE_SCRIPT                 4
#define MODULETYPE_LIBRARY                8              // not an independent program


// MQL program types
#define PROGRAMTYPE_INDICATOR             MODULETYPE_INDICATOR
#define PROGRAMTYPE_EXPERT                MODULETYPE_EXPERT
#define PROGRAMTYPE_SCRIPT                MODULETYPE_SCRIPT


// MQL program launch types
#define LAUNCHTYPE_TEMPLATE               1              // loaded by applying a template
#define LAUNCHTYPE_PROGRAM                2              // loaded by iCustom()
#define LAUNCHTYPE_MANUAL                 3              // loaded manually


// MQL core function ids
#define COREFUNCTION_INIT                 1
#define COREFUNCTION_START                2
#define COREFUNCTION_DEINIT               3
                                                         // +--------------------------------------+----------------------------------+
                                                         // | builds <= 509                        | builds > 509                     |
// built-in UninitializeReason() return values           // +--------------------------------------+----------------------------------+
#define REASON_UNDEFINED                  0              // | no reason                            | -                                |
#define REASON_PROGRAM     REASON_UNDEFINED              // | -                                    | expert removed by ExpertRemove() |
                                                         // +--------------------------------------+----------------------------------+
#define REASON_REMOVE                     1              // | program removed from chart                                              |
#define REASON_RECOMPILE                  2              // | program recompiled                                                      |
#define REASON_CHARTCHANGE                3              // | chart symbol or timeframe changed                                       |
                                                         // +--------------------------------------+----------------------------------+
#define REASON_CHARTCLOSE                 4              // | chart closed or new template applied | chart closed                     |
                                                         // +--------------------------------------+----------------------------------+
#define REASON_PARAMETERS                 5              // | input parameters changed                                                |
#define REASON_ACCOUNT                    6              // | reconnection due to a changed trading account                           |
                                                         // +--------------------------------------+----------------------------------+
#define REASON_TEMPLATE                   7              // | -                                    | new template applied             |
#define REASON_INITFAILED                 8              // | -                                    | OnInit() returned an error       |
#define REASON_CLOSE                      9              // | -                                    | terminal closed                  |
                                                         // +--------------------------------------+----------------------------------+

// framework InitializeReason codes                      // +-- init reason --------------------------------+-- ui -----------+-- applies --+
#define INITREASON_USER                   1              // | loaded by the user (also in tester)           |    input dialog |   I, E, S   |   I = indicators
#define INITREASON_TEMPLATE               2              // | loaded by a template (also at terminal start) | no input dialog |   I, E      |   E = experts
#define INITREASON_PROGRAM                3              // | loaded by iCustom()                           | no input dialog |   I         |   S = scripts
#define INITREASON_PROGRAM_AFTERTEST      4              // | loaded by iCustom() after end of test         | no input dialog |   I         |
#define INITREASON_PARAMETERS             5              // | input parameters changed                      |    input dialog |   I, E      |
#define INITREASON_TIMEFRAMECHANGE        6              // | chart period changed                          | no input dialog |   I, E      |
#define INITREASON_SYMBOLCHANGE           7              // | chart symbol changed                          | no input dialog |   I, E      |
#define INITREASON_RECOMPILE              8              // | reloaded after recompilation                  | no input dialog |   I, E      |
#define INITREASON_TERMINAL_FAILURE       9              // | terminal failure                              |    input dialog |      E      |   @see https://github.com/rosasurfer/mt4-mql/issues/1
                                                         // +-----------------------------------------------+-----------------+-------------+

// UninitializeReason codes (matching the MetaQuotes REASON_* codes)
#define UNINITREASON_UNDEFINED            0
#define UNINITREASON_REMOVE               1
#define UNINITREASON_RECOMPILE            2
#define UNINITREASON_CHARTCHANGE          3
#define UNINITREASON_CHARTCLOSE           4
#define UNINITREASON_PARAMETERS           5
#define UNINITREASON_ACCOUNT              6
#define UNINITREASON_TEMPLATE             7
#define UNINITREASON_INITFAILED           8
#define UNINITREASON_CLOSE                9


// timeframe identifiers
#define PERIOD_M1                         1              // 1 minute
#define PERIOD_M5                         5              // 5 minutes
#define PERIOD_M15                       15              // 15 minutes
#define PERIOD_M30                       30              // 30 minutes
#define PERIOD_H1                        60              // 1 hour
#define PERIOD_H4                       240              // 4 hours
#define PERIOD_D1                      1440              // 1 Tag
#define PERIOD_W1                     10080              // 1 week (7 days)
#define PERIOD_MN1                    43200              // 1 month (30 days)
#define PERIOD_Q1                    129600              // 1 quarter (3 months)


// order and operation types
#define OP_UNDEFINED                     -1              // custom: default value of a non-initialized type var
#define OP_BUY                            0              // long position
#define OP_LONG                      OP_BUY
#define OP_SELL                           1              // short position
#define OP_SHORT                    OP_SELL
#define OP_BUYLIMIT                       2              // buy limit order
#define OP_SELLLIMIT                      3              // sell limit order
#define OP_BUYSTOP                        4              // stop buy order
#define OP_SELLSTOP                       5              // stop sell order
#define OP_BALANCE                        6              // account debit or credit transaction
#define OP_CREDIT                         7              // margin credit facility (no transaction)


// pending order activation types
#define OA_LIMIT                          1
#define OA_STOP                           2


// trade directions, may be used as flags
#define TRADE_DIRECTION_LONG              1
#define TRADE_DIRECTION_SHORT             2
#define TRADE_DIRECTION_BOTH              3


// file system related constants
#define MKDIR_PARENT                      1              // create non-existing parent directories as needed => @see CreateDirectory()


// time constants
#define SECOND                            1
#define MINUTE                           60              //  60 seconds
#define HOUR                           3600              //  60 minutes
#define DAY                           86400              //  24 hours
#define WEEK                         604800              //   7 days
#define MONTH                       2678400              //  31 days                   // Values cover the maximum possible range, so
#define QUARTER                     8035200              //   3 months (3 x 31 days)   // results of date/time calculations are garantied
#define YEAR                       31622400              // 366 days                   // to be in the next period.

#define SECONDS                      SECOND
#define MINUTES                      MINUTE
#define HOURS                          HOUR
#define DAYS                            DAY
#define WEEKS                          WEEK
#define MONTHS                        MONTH
#define QUARTERS                    QUARTER
#define YEARS                          YEAR


// weekday constants based on Sunday=0; same behaviour as DayOfWeek() and TimeDayOfWeek()
#define SUNDAY                            0
#define MONDAY                            1
#define TUESDAY                           2
#define WEDNESDAY                         3
#define THURSDAY                          4
#define FRIDAY                            5
#define SATURDAY                          6

#define SUN                          SUNDAY
#define MON                          MONDAY
#define TUE                         TUESDAY
#define WED                       WEDNESDAY
#define THU                        THURSDAY
#define FRI                          FRIDAY
#define SAT                        SATURDAY


// month constants based on January=0
#define zJANUARY                          0
#define zFEBRUARY                         1
#define zMARCH                            2
#define zAPRIL                            3
#define zMAY                              4
#define zJUNE                             5
#define zJULY                             6
#define zAUGUST                           7
#define zSEPTEMBER                        8
#define zOCTOBER                          9
#define zNOVEMBER                        10
#define zDECEMBER                        11

#define zJAN                       zJANUARY
#define zFEB                      zFEBRUARY
#define zMAR                         zMARCH
#define zAPR                         zAPRIL
//      zMAY                           zMAY              // short form equals long form
#define zJUN                          zJUNE
#define zJUL                          zJULY
#define zAUG                        zAUGUST
#define zSEP                     zSEPTEMBER
#define zOCT                       zOCTOBER
#define zNOV                      zNOVEMBER
#define zDEC                      zDECEMBER


// month constants based on January=1; same behaviour as Month() and TimeMonth()
#define JANUARY                           1
#define FEBRUARY                          2
#define MARCH                             3
#define APRIL                             4
#define MAY                               5
#define JUNE                              6
#define JULY                              7
#define AUGUST                            8
#define SEPTEMBER                         9
#define OCTOBER                          10
#define NOVEMBER                         11
#define DECEMBER                         12

#define JAN                         JANUARY
#define FEB                        FEBRUARY
#define MAR                           MARCH
#define APR                           APRIL
//      MAY                             MAY              // short form equals long form
#define JUN                            JUNE
#define JUL                            JULY
#define AUG                          AUGUST
#define SEP                       SEPTEMBER
#define OCT                         OCTOBER
#define NOV                        NOVEMBER
#define DEC                        DECEMBER


// init() flags
#define INIT_TIMEZONE                     1              // initialize/check the timezone configuration
#define INIT_PIPVALUE                     2              // check availability of the current pip value (requires tick size and value)
#define INIT_BARS_ON_HIST_UPDATE          4              //
#define INIT_NO_BARS_REQUIRED             8              // executable without history (scripts only)


// known timezones
#define TIMEZONE_ALPARI                   "Alpari"             // until 03/2012 "Europe/Berlin", after "Europe/Kiev"
#define TIMEZONE_AMERICA_NEW_YORK         "America/New_York"
#define TIMEZONE_EUROPE_BERLIN            "Europe/Berlin"
#define TIMEZONE_EUROPE_KIEV              "Europe/Kiev"
#define TIMEZONE_EUROPE_LONDON            "Europe/London"
#define TIMEZONE_EUROPE_MINSK             "Europe/Minsk"
#define TIMEZONE_FXT                      "FXT"                // "Europe/Kiev"   with DST changes of "America/New_York"
#define TIMEZONE_FXT_MINUS_0200           "FXT-0200"           // "Europe/London" with DST changes of "America/New_York"
#define TIMEZONE_GLOBALPRIME              "GlobalPrime"        // until 24.10.2015 "FXT", then a single time "Europe/Kiev", then "FXT" again
#define TIMEZONE_GMT                      "GMT"


// known timezone ids
#define TIMEZONE_ID_ALPARI                1
#define TIMEZONE_ID_AMERICA_NEW_YORK      2
#define TIMEZONE_ID_EUROPE_BERLIN         3
#define TIMEZONE_ID_EUROPE_KIEV           4
#define TIMEZONE_ID_EUROPE_LONDON         5
#define TIMEZONE_ID_EUROPE_MINSK          6
#define TIMEZONE_ID_FXT                   7
#define TIMEZONE_ID_FXT_MINUS_0200        8
#define TIMEZONE_ID_GLOBALPRIME           9
#define TIMEZONE_ID_GMT                  10


// MT4 internal messages
#define MT4_TICK                          2              // a virtual tick, triggers start()

#define MT4_LOAD_STANDARD_INDICATOR      13
#define MT4_LOAD_CUSTOM_INDICATOR        15
#define MT4_LOAD_EXPERT                  14
#define MT4_LOAD_SCRIPT                  16

#define MT4_OPEN_CHART                   51

#define MT4_COMPILE_REQUEST           12345
#define MT4_COMPILE_PERMISSION        12346
#define MT4_MQL_REFRESH               12349              // rescan und reload modified .ex4 files


// bar model types in tester
#define BARMODEL_EVERYTICK                0
#define BARMODEL_CONTROLPOINTS            1
#define BARMODEL_BAROPEN                  2


// configuration flags for synthetic ticks
#define TICK_OFFLINE_EA                   1              // send a standard tick, triggers Expert::start() in offline charts if a server connection is established
#define TICK_CHART_REFRESH                2              // send command ID_CHART_REFRESH instead of a standard tick (for offline charts and custom symbols)
#define TICK_TESTER                       4              // send command ID_CHART_STEPFORWARD instead of a standard tick (for tester)
#define TICK_IF_VISIBLE                   8              // send ticks only if the chart is at least partially visible (default: off)
#define TICK_PAUSE_ON_WEEKEND            16              // send ticks only at regular session times (default: off)


/**
 * MT4 command ids (menu, toolbar and hotkey ids). ID naming and numbering conventions for resources, commands, strings,
 * controls and child windows as defined by MFC 2.0:
 *
 *  @see  https://msdn.microsoft.com/en-us/library/t2zechd4.aspx
 */
#define ID_EXPERTS_ONOFF                    33020        // Toolbar: Experts on/off                    Ctrl+E

#define ID_CHART_REFRESH                    33324        // Chart:   Refresh
#define ID_CHART_STEPFORWARD                33197        //          One bar forward                      F12
#define ID_CHART_STEPBACKWARD               33198        //          One bar backward               Shift+F12
#define ID_CHART_EXPERT_PROPERTIES          33048        //          Expert properties dialog              F7
#define ID_CHART_OBJECTS_UNSELECTALL        35462        //          Objects: Unselect All

#define ID_WINDOW_NEWWINDOW                 57648        // Window:  New Window
#define ID_WINDOW_TILEWINDOWS               38259        //          Tile Windows                       Alt+R
#define ID_WINDOW_CASCADE                   57650        //          Cascade
#define ID_WINDOW_TILEHORIZONTALLY          57651        //          Tile Horizontally
#define ID_WINDOW_TILEVERTICALLY            57652        //          Tile Vertically
#define ID_WINDOW_ARRANGEICONS              57649        //          Arrange Icons

#define ID_MARKETWATCH_SYMBOLS              33171        // Market Watch: Symbols

#define ID_TESTER_TICK       ID_CHART_STEPFORWARD        // Tester:  Next Tick                            F12


// MT4 control ids (controls, windows)
#define IDC_TOOLBAR                         59419        // Toolbar
#define IDC_TOOLBAR_COMMUNITY_BUTTON        38160        // MQL4/MQL5 button (builds <= 509)
#define IDC_TOOLBAR_SEARCHBOX               38213        // search box       (builds >  509)
#define IDC_STATUSBAR                       59393        // status bar
#define IDC_MDI_CLIENT                      59648        // MDI container (holding all charts)
#define IDC_DOCKABLES_CONTAINER             59422        // window containing all child windows docked to the main application window
#define IDC_UNDOCKED_CONTAINER              59423        // window containing a single undocked/floating dockable child window (possibly more than one, not a toplevel window)

#define IDC_CUSTOM_INDICATOR_OK                 1        // load dialog "Custom Indicator"
#define IDC_CUSTOM_INDICATOR_CANCEL             2        // ...
#define IDC_CUSTOM_INDICATOR_RESET          12321        // ...

#define IDC_MARKETWATCH                        80        // Market Watch
#define IDC_MARKETWATCH_SYMBOLS             35441        // Market Watch - Symbols
#define IDC_MARKETWATCH_TICKCHART           35442        // Market Watch - Tick Chart

#define IDC_NAVIGATOR                          82        // Navigator
#define IDC_NAVIGATOR_COMMON                35439        // Navigator - Common
#define IDC_NAVIGATOR_FAVOURITES            35440        // Navigator - Favourites

#define IDC_TERMINAL                           81        // Terminal
#define IDC_TERMINAL_TRADE                  33217        // Terminal - Trade
#define IDC_TERMINAL_ACCOUNTHISTORY         33208        // Terminal - Account History
#define IDC_TERMINAL_NEWS                   33211        // Terminal - News
#define IDC_TERMINAL_ALERTS                 33206        // Terminal - Alerts
#define IDC_TERMINAL_MAILBOX                33210        // Terminal - Mailbox
#define IDC_TERMINAL_COMPANY                 4078        // Terminal - Company
#define IDC_TERMINAL_MARKET                  4081        // Terminal - Market
#define IDC_TERMINAL_SIGNALS                 1405        // Terminal - Signals
#define IDC_TERMINAL_CODEBASE               33212        // Terminal - Code Base
#define IDC_TERMINAL_EXPERTS                35434        // Terminal - Experts
#define IDC_TERMINAL_JOURNAL                33209        // Terminal - Journal

#define IDC_TESTER                             83        // Tester
#define IDC_TESTER_SETTINGS                 33215        // Tester - Settings
#define IDC_TESTER_SETTINGS_EXPERT           1128        // Tester - Settings - expert selection
#define IDC_TESTER_SETTINGS_SYMBOL           1347        // Tester - Settings - symbol selection
#define IDC_TESTER_SETTINGS_BARMODEL         4027        // Tester - Settings - bar model selection
#define IDC_TESTER_SETTINGS_OPTIMIZATION     1029        // Tester - Settings - optimization checkbox
#define IDC_TESTER_SETTINGS_PERIOD           1228        // Tester - Settings - period selection
#define IDC_TESTER_SETTINGS_USEDATE          1023        // Tester - Settings - "Use date" checkbox
#define IDC_TESTER_SETTINGS_VISUALMODE       1400        // Tester - Settings - visual mode checkbox
#define IDC_TESTER_SETTINGS_TRACKBAR         1401        // Tester - Settings - speed slider
#define IDC_TESTER_SETTINGS_PAUSERESUME      1402        // Tester - Settings - "Pause/Resume" button
#define IDC_TESTER_SETTINGS_SKIPTO           1403        // Tester - Settings - "Skip to" button
#define IDC_TESTER_SETTINGS_EXPERTPROPS      1025        // Tester - Settings - expert properties button
#define IDC_TESTER_SETTINGS_SYMBOLPROPS      1030        // Tester - Settings - symbol properties button
#define IDC_TESTER_SETTINGS_OPENCHART        1028        // Tester - Settings - "Open chart" button
#define IDC_TESTER_SETTINGS_MODIFYEXPERT     1399        // Tester - Settings - "Modify expert" button
#define IDC_TESTER_SETTINGS_STARTSTOP        1034        // Tester - Settings - "Start/Stop" button
#define IDC_TESTER_RESULTS                  33214        // Tester - Results
#define IDC_TESTER_GRAPH                    33207        // Tester - Graph
#define IDC_TESTER_REPORT                   33213        // Tester - Report
#define IDC_TESTER_JOURNAL   IDC_TERMINAL_EXPERTS        // Tester - Journal (same as Terminal - Experts)


// colors
#define AliceBlue                        0xFFF8F0
#define AntiqueWhite                     0xD7EBFA
#define Aqua                             0xFFFF00
#define Aquamarine                       0xD4FF7F
#define Beige                            0xDCF5F5
#define Bisque                           0xC4E4FF
#define Black                            0x000000
#define BlanchedAlmond                   0xCDEBFF
#define Blue                             0xFF0000
#define BlueViolet                       0xE22B8A
#define Brown                            0x2A2AA5
#define BurlyWood                        0x87B8DE
#define CadetBlue                        0xA09E5F
#define Chartreuse                       0x00FF7F
#define Chocolate                        0x1E69D2
#define Coral                            0x507FFF
#define CornflowerBlue                   0xED9564
#define Cornsilk                         0xDCF8FF
#define Crimson                          0x3C14DC
#define Cyan                                 Aqua        // alias
#define DarkBlue                         0x8B0000
#define DarkGoldenrod                    0x0B86B8
#define DarkGray                         0xA9A9A9
#define DarkGreen                        0x006400
#define DarkKhaki                        0x6BB7BD
#define DarkOliveGreen                   0x2F6B55
#define DarkOrange                       0x008CFF
#define DarkOrchid                       0xCC3299
#define DarkSalmon                       0x7A96E9
#define DarkSeaGreen                     0x8BBC8F
#define DarkSlateBlue                    0x8B3D48
#define DarkSlateGray                    0x4F4F2F
#define DarkTurquoise                    0xD1CE00
#define DarkViolet                       0xD30094
#define DeepPink                         0x9314FF
#define DeepSkyBlue                      0xFFBF00
#define DimGray                          0x696969
#define DodgerBlue                       0xFF901E
#define FireBrick                        0x2222B2
#define ForestGreen                      0x228B22
#define Gainsboro                        0xDCDCDC
#define Gold                             0x00D7FF
#define Goldenrod                        0x20A5DA
#define Gray                             0x808080
#define Green                            0x008000
#define GreenYellow                      0x2FFFAD
#define Honeydew                         0xF0FFF0
#define HotPink                          0xB469FF
#define IndianRed                        0x5C5CCD
#define Indigo                           0x82004B
#define Ivory                            0xF0FFFF
#define Khaki                            0x8CE6F0
#define Lavender                         0xFAE6E6
#define LavenderBlush                    0xF5F0FF
#define LawnGreen                        0x00FC7C
#define LemonChiffon                     0xCDFAFF
#define LightBlue                        0xE6D8AD
#define LightCoral                       0x8080F0
#define LightCyan                        0xFFFFE0
#define LightGoldenrod                   0xD2FAFA
#define LightGray                        0xD3D3D3
#define LightGreen                       0x90EE90
#define LightPink                        0xC1B6FF
#define LightSalmon                      0x7AA0FF
#define LightSeaGreen                    0xAAB220
#define LightSkyBlue                     0xFACE87
#define LightSlateGray                   0x998877
#define LightSteelBlue                   0xDEC4B0
#define LightYellow                      0xE0FFFF
#define Lime                             0x00FF00
#define LimeGreen                        0x32CD32
#define Linen                            0xE6F0FA
#define Magenta                          0xFF00FF
#define Maroon                           0x000080
#define MediumAquamarine                 0xAACD66
#define MediumBlue                       0xCD0000
#define MediumOrchid                     0xD355BA
#define MediumPurple                     0xDB7093
#define MediumSeaGreen                   0x71B33C
#define MediumSlateBlue                  0xEE687B
#define MediumSpringGreen                0x9AFA00
#define MediumTurquoise                  0xCCD148
#define MediumVioletRed                  0x8515C7
#define MidnightBlue                     0x701919
#define MintCream                        0xFAFFF5
#define MistyRose                        0xE1E4FF
#define Moccasin                         0xB5E4FF
#define NavajoWhite                      0xADDEFF
#define Navy                             0x800000
#define OldLace                          0xE6F5FD
#define Olive                            0x008080
#define OliveDrab                        0x238E6B
#define Orange                           0x00A5FF
#define OrangeRed                        0x0045FF
#define Orchid                           0xD670DA
#define PaleGoldenrod                    0xAAE8EE
#define PaleGreen                        0x98FB98
#define PaleTurquoise                    0xEEEEAF
#define PaleVioletRed                    0x9370DB
#define PapayaWhip                       0xD5EFFF
#define PeachPuff                        0xB9DAFF
#define Peru                             0x3F85CD
#define Pink                             0xCBC0FF
#define Plum                             0xDDA0DD
#define PowderBlue                       0xE6E0B0
#define Purple                           0x800080
#define Red                              0x0000FF
#define RosyBrown                        0x8F8FBC
#define RoyalBlue                        0xE16941
#define SaddleBrown                      0x13458B
#define Salmon                           0x7280FA
#define SandyBrown                       0x60A4F4
#define SeaGreen                         0x578B2E
#define Seashell                         0xEEF5FF
#define Sienna                           0x2D52A0
#define Silver                           0xC0C0C0
#define SkyBlue                          0xEBCE87
#define SlateBlue                        0xCD5A6A
#define SlateGray                        0x908070
#define Snow                             0xFAFAFF
#define SpringGreen                      0x7FFF00
#define SteelBlue                        0xB48246
#define Tan                              0x8CB4D2
#define Teal                             0x808000
#define Thistle                          0xD8BFD8
#define Tomato                           0x4763FF
#define Turquoise                        0xD0E040
#define Violet                           0xEE82EE
#define Wheat                            0xB3DEF5
#define White                            0xFFFFFF
#define WhiteSmoke                       0xF5F5F5
#define Yellow                           0x00FFFF
#define YellowGreen                      0x32CD9A

#define clrAliceBlue                     AliceBlue
#define clrAntiqueWhite                  AntiqueWhite
#define clrAqua                          Aqua
#define clrAquamarine                    Aquamarine
#define clrBeige                         Beige
#define clrBisque                        Bisque
#define clrBlack                         Black
#define clrBlanchedAlmond                BlanchedAlmond
#define clrBlue                          Blue
#define clrBlueViolet                    BlueViolet
#define clrBrown                         Brown
#define clrBurlyWood                     BurlyWood
#define clrCadetBlue                     CadetBlue
#define clrChartreuse                    Chartreuse
#define clrChocolate                     Chocolate
#define clrCoral                         Coral
#define clrCornflowerBlue                CornflowerBlue
#define clrCornsilk                      Cornsilk
#define clrCrimson                       Crimson
#define clrDarkBlue                      DarkBlue
#define clrDarkGoldenrod                 DarkGoldenrod
#define clrDarkGray                      DarkGray
#define clrDarkGreen                     DarkGreen
#define clrDarkKhaki                     DarkKhaki
#define clrDarkOliveGreen                DarkOliveGreen
#define clrDarkOrange                    DarkOrange
#define clrDarkOrchid                    DarkOrchid
#define clrDarkSalmon                    DarkSalmon
#define clrDarkSeaGreen                  DarkSeaGreen
#define clrDarkSlateBlue                 DarkSlateBlue
#define clrDarkSlateGray                 DarkSlateGray
#define clrDarkTurquoise                 DarkTurquoise
#define clrDarkViolet                    DarkViolet
#define clrDeepPink                      DeepPink
#define clrDeepSkyBlue                   DeepSkyBlue
#define clrDimGray                       DimGray
#define clrDodgerBlue                    DodgerBlue
#define clrFireBrick                     FireBrick
#define clrForestGreen                   ForestGreen
#define clrGainsboro                     Gainsboro
#define clrGold                          Gold
#define clrGoldenrod                     Goldenrod
#define clrGray                          Gray
#define clrGreen                         Green
#define clrGreenYellow                   GreenYellow
#define clrHoneydew                      Honeydew
#define clrHotPink                       HotPink
#define clrIndianRed                     IndianRed
#define clrIndigo                        Indigo
#define clrIvory                         Ivory
#define clrKhaki                         Khaki
#define clrLavender                      Lavender
#define clrLavenderBlush                 LavenderBlush
#define clrLawnGreen                     LawnGreen
#define clrLemonChiffon                  LemonChiffon
#define clrLightBlue                     LightBlue
#define clrLightCoral                    LightCoral
#define clrLightCyan                     LightCyan
#define clrLightGoldenrod                LightGoldenrod
#define clrLightGray                     LightGray
#define clrLightGreen                    LightGreen
#define clrLightPink                     LightPink
#define clrLightSalmon                   LightSalmon
#define clrLightSeaGreen                 LightSeaGreen
#define clrLightSkyBlue                  LightSkyBlue
#define clrLightSlateGray                LightSlateGray
#define clrLightSteelBlue                LightSteelBlue
#define clrLightYellow                   LightYellow
#define clrLime                          Lime
#define clrLimeGreen                     LimeGreen
#define clrLinen                         Linen
#define clrMagenta                       Magenta
#define clrMaroon                        Maroon
#define clrMediumAquamarine              MediumAquamarine
#define clrMediumBlue                    MediumBlue
#define clrMediumOrchid                  MediumOrchid
#define clrMediumPurple                  MediumPurple
#define clrMediumSeaGreen                MediumSeaGreen
#define clrMediumSlateBlue               MediumSlateBlue
#define clrMediumSpringGreen             MediumSpringGreen
#define clrMediumTurquoise               MediumTurquoise
#define clrMediumVioletRed               MediumVioletRed
#define clrMidnightBlue                  MidnightBlue
#define clrMintCream                     MintCream
#define clrMistyRose                     MistyRose
#define clrMoccasin                      Moccasin
#define clrNavajoWhite                   NavajoWhite
#define clrNavy                          Navy
#define clrOldLace                       OldLace
#define clrOlive                         Olive
#define clrOliveDrab                     OliveDrab
#define clrOrange                        Orange
#define clrOrangeRed                     OrangeRed
#define clrOrchid                        Orchid
#define clrPaleGoldenrod                 PaleGoldenrod
#define clrPaleGreen                     PaleGreen
#define clrPaleTurquoise                 PaleTurquoise
#define clrPaleVioletRed                 PaleVioletRed
#define clrPapayaWhip                    PapayaWhip
#define clrPeachPuff                     PeachPuff
#define clrPeru                          Peru
#define clrPink                          Pink
#define clrPlum                          Plum
#define clrPowderBlue                    PowderBlue
#define clrPurple                        Purple
#define clrRed                           Red
#define clrRosyBrown                     RosyBrown
#define clrRoyalBlue                     RoyalBlue
#define clrSaddleBrown                   SaddleBrown
#define clrSalmon                        Salmon
#define clrSandyBrown                    SandyBrown
#define clrSeaGreen                      SeaGreen
#define clrSeashell                      Seashell
#define clrSienna                        Sienna
#define clrSilver                        Silver
#define clrSkyBlue                       SkyBlue
#define clrSlateBlue                     SlateBlue
#define clrSlateGray                     SlateGray
#define clrSnow                          Snow
#define clrSpringGreen                   SpringGreen
#define clrSteelBlue                     SteelBlue
#define clrTan                           Tan
#define clrTeal                          Teal
#define clrThistle                       Thistle
#define clrTomato                        Tomato
#define clrTurquoise                     Turquoise
#define clrViolet                        Violet
#define clrWheat                         Wheat
#define clrWhite                         White
#define clrWhiteSmoke                    WhiteSmoke
#define clrYellow                        Yellow
#define clrYellowGreen                   YellowGreen


// LFX trade commands
#define TC_LFX_ORDER_CREATE              1
#define TC_LFX_ORDER_OPEN                2
#define TC_LFX_ORDER_CLOSE               3
#define TC_LFX_ORDER_CLOSEBY             4
#define TC_LFX_ORDER_HEDGE               5
#define TC_LFX_ORDER_MODIFY              6
#define TC_LFX_ORDER_DELETE              7
