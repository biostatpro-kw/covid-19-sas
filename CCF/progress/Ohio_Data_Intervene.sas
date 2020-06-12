/* directory path for files: COVID_19.sas (this file), libname store */
%let homedir = C:\COVID19;

/* the storage location for the MODEL_FINAL table and the SCENARIOS table */
libname store "&homedir.";

/* User Interface Switches - these are used if you using the code within SAS Visual Analytics UI */
%LET ScenarioSource = BATCH;

PROC SQL NOPRINT;
	SELECT MIN(DATE) INTO :FIRST_CASE FROM STORE.FIT_INPUT;
	SELECT "'"||PUT(MIN(DATE),DATE9.)||"'"||"D" INTO :DAY_ZERO FROM STORE.FIT_INPUT;
	SELECT MAX(DATE) INTO :LATEST_CASE FROM STORE.FIT_INPUT;
QUIT;

%LET scenario=Scenario_DrS_00_40_run_12;
%LET IncubationPeriod=0;
%LET InitRecovered=0;
%LET RecoveryDays=14;
%LET doublingtime=5;
%LET KnownAdmits=10;
%LET Population=4390484;
%LET SocialDistancing=0.0;
%LET MarketSharePercent=0.29;
%LET Admission_Rate=0.075;
%LET ICUPercent=0.45;
%LET VentPErcent=0.35;
%LET ISOChangeDate='27MAR2020'd:'06APR2020'd:'20APR2020'd:'01MAY2020'd;
%LET ISOChangeEvent=Social Distance:Essential Businesses:Shelter In Place:Reopen;
%LET ISOChangeWindow=1:1:1:1;
%LET SocialDistancingChange=0:0.2:0.3:-0.2;
%LET FatalityRate=0.0;
%LET plots=YES;
%LET N_DAYS = 1000;
%LET DiagnosedRate = 1.0;
%LET E = 0;
%LET SIGMA = 3;
/*%LET DAY_ZERO = '13MAR2020'd;*/
%LET ECMO_RATE=0.03; 
%LET DIAL_RATE=0.05;
%LET HOSP_LOS = 7;
%LET ICU_LOS = 9;
%LET VENT_LOS = 10;
%LET ECMO_LOS=6;
%LET DIAL_LOS=11;

%LET SCENARIOINDEX = 1;

/* Calculate Parameters form Macro Inputs Here - these are repeated as comments at the start of each model phase below */
* calculated parameters used in model post-processing;
%LET HOSP_RATE = %SYSEVALF(&Admission_Rate. * &DiagnosedRate.);
%LET ICU_RATE = %SYSEVALF(&ICUPercent. * &DiagnosedRate.);
%LET VENT_RATE = %SYSEVALF(&VentPErcent. * &DiagnosedRate.);
* calculated parameters used in models;
%LET I = %SYSEVALF(&KnownAdmits. / 
							&MarketSharePercent. / 
								(&Admission_Rate. * &DiagnosedRate.));
%LET GAMMA = %SYSEVALF(1 / &RecoveryDays.);
/*%IF &SIGMA. <= 0 %THEN %LET SIGMA = 0.00000001;*/
%LET SIGMAINV = %SYSEVALF(1 / &SIGMA.);
%LET BETA = %SYSEVALF(((2 ** (1 / &doublingtime.) - 1) + &GAMMA.) / 
								&Population. * (1 - &SocialDistancing.));
%LET R_T = %SYSEVALF(&BETA. / &GAMMA. * &Population.);

%MACRO SD;

%IF %sysevalf(%superq(SocialDistancingChange)=,boolean)=0 %THEN %DO;
	%GLOBAL sdchangetitle;
	%LET sdchangetitle=Adjust R0 (Date / Event / R0 / Social Distancing Shift):;
	%LET ISOChangeLoop = %SYSFUNC(countw(&SocialDistancingChange.,:));
	%DO j = 1 %TO &ISOChangeLoop;
		%GLOBAL SocialDistancingChange&j ISOChangeDate&j ISOChangeEvent&j ISOChangeWindow&j 
			BETAChange&j R_T_Change&j;
		%LET SocialDistancingChange&j = %scan(&SocialDistancingChange.,&j,:);
		%LET ISOChangeDate&j = %scan(&ISOChangeDate.,&j,:);
		%LET ISOChangeEvent&j = %scan(&ISOChangeEvent.,&j,:);
		%LET ISOChangeWindow&j = %scan(&ISOChangeWindow.,&j,:);
		%LET BETAChange&j = %SYSEVALF(((2 ** (1 / &doublingtime.) - 1) + &GAMMA.) / 
								&Population. * ((&&SocialDistancingChange&j)/&&ISOChangeWindow&j));
		%IF &j = 1 %THEN %LET R_T_Change&j = %SYSEVALF(&R_T - &&BETAChange&j / &GAMMA. * &Population.);
		%ELSE %DO;
			%LET j2=%eval(&j-1);
			%LET R_T_Change&j = %SYSEVALF(&&R_T_Change&j2 - &&BETAChange&j / &GAMMA. * &Population.);
		%END;
		%LET sdchangetitle = &sdchangetitle. (%sysfunc(INPUTN(&&ISOChangeDate&j., date10.), date9.) / &&ISOChangeEvent&j / %SYSFUNC(round(&&R_T_Change&j,.01)) / %SYSEVALF(&&SocialDistancingChange&j.*100)%);
	%END; 
%END;
%ELSE %DO;
	%LET sdchangetitle=No Adjustment to R0 over time;
%END;

%MEND SD;

%SD;

/*Smooth Fit Approach*/
PROC TMODEL DATA = STORE.FIT_INPUT(WHERE=(DATE<=%SYSEVALF(&LATEST_CASE-15))) OUTMODEL=SEIRMOD_I_SMOOTH; 
	/* Parameters of interest */
	PARMS R0 &R_T. RMIN 0.1 I0 &I. DI &ISOChangeDate1. DSTD 7;
	BOUNDS 1 <= R0 <= 10;
	BOUNDS RMIN > 0;
	/* Fixed values */
	CONTROL SIGMAINV &SIGMAINV. 
			INF &RecoveryDays.;
	N = &Population.;
	/* Coefficient parameterizations */
	GAMMA = 1 / INF;
	STEP = CDF('NORMAL',DATE, DI, DSTD);
	BETA = (R0*(1 - STEP) + RMIN*STEP)*GAMMA/N;
	/* Differential equations */
	/* a. Decrease in healthy susceptible persons through infections: number of encounters of (S,I)*TransmissionProb*/
	DERT.S_N = -BETA * S_N * I_N;
	/* b. inflow from a. -Decrease in Exposed: alpha*e "promotion" inflow from E->I;*/
	DERT.E_N = BETA * S_N * I_N - SIGMAINV * E_N;
	/* c. inflow from b. - outflow through recovery or death during illness*/
	DERT.I_N = SIGMAINV * E_N - GAMMA * I_N;
	/* d. Recovered and death humans through "promotion" inflow from c.*/
	DERT.R_N = GAMMA * I_N;
	CUMULATIVE_CASE_COUNT = I_N + R_N;
	OUTVARS S_N E_N I_N R_N;
	ESTIMATE R0, RMIN, I0, DI, DSTD, / OUTCOV;
	/* Fit the data */
	FIT CUMULATIVE_CASE_COUNT INIT=(S_N=&Population. E_N=0 I_N=I0 R_N=0) / TIME=TIME DYNAMIC OUTPREDICT OUTACTUAL OUT=FIT_PRED LTEBOUND=1E-10 OUTEST=FIT_PARMS
		OPTIMIZER=ORMP(OPTTOL=1E-5);
QUIT;

PROC SQL NOPRINT;
	SELECT R0 INTO :R0_FIT FROM FIT_PARMS;
	SELECT "'"||PUT(DI,DATE9.)||"'"||"D" INTO :CURVEBEND1 FROM FIT_PARMS;
	SELECT RMIN INTO :R0_BEND_FIT FROM FIT_PARMS;
	SELECT DSTD INTO :DSTD FROM FIT_PARMS;
	SELECT "'"||PUT(DI-2*&DSTD,DATE9.)||"'"||"D" INTO :CURVEBENDSTART FROM FIT_PARMS;
	SELECT "'"||PUT(DI+2*&DSTD,DATE9.)||"'"||"D" INTO :CURVEBENDSTOP FROM FIT_PARMS;
	SELECT I0 INTO :I0 FROM FIT_PARMS;
QUIT;

%LET SOC_DIST_FIT = %SYSEVALF(1 - &R0_BEND_FIT / &R0_FIT);
%LET SOC_DIST_FIT_WINDOW = %SYSFUNC(ROUND(%SYSEVALF(4*&DSTD)));

%PUT CURVEBEND1 = &CURVEBEND1;
%PUT CURVEBENDSTART = &CURVEBENDSTART;
%PUT CURVEBENDSTOP = &CURVEBENDSTOP;
%PUT DSTD = &DSTD;
%PUT SOC_DIST_FIT_WINDOW = &SOC_DIST_FIT_WINDOW;
%PUT R0_FIT = &R0_FIT;
%PUT R0_BEND_FIT = &R0_BEND_FIT;
%PUT SOC_DIST_FIT = &SOC_DIST_FIT;
%PUT I0 = &I0;

DATA FIT_PRED;
	SET FIT_PRED;
	LABEL CUMULATIVE_CASE_COUNT='Cumulative Incidence';
	FORMAT DATE DATE9.; 
	DATE = &FIRST_CASE. + TIME -1;
run;

PROC SGPLOT DATA=FIT_PRED;
	WHERE _TYPE_  NE 'RESIDUAL';
	TITLE "Actual v. Predicted Cumulative Infections in Region";
	TITLE2 "Initial Reproductive Number (R0): %SYSFUNC(round(&R0_FIT.,.01))";
	TITLE3 "Social Distancing Increased to %SYSFUNC(round(%SYSEVALF(&SOC_DIST_FIT.*100)))% between %sysfunc(INPUTN(&CURVEBENDSTART., date10.), date9.) and %sysfunc(INPUTN(&CURVEBENDSTOP., date10.), date9.)";
	TITLE4 "Adjusted Reproductive Number: %SYSFUNC(round(&R0_BEND_FIT.,.01))";
	SERIES X=DATE Y=CUMULATIVE_CASE_COUNT / LINEATTRS=(THICKNESS=2) GROUP=_TYPE_  MARKERS NAME="cases";
	FORMAT CUMULATIVE_CASE_COUNT COMMA10.;
RUN;
TITLE;TITLE2;TITLE3;TITLE4;

PROC SQL;
	CREATE TABLE PLOTFIT AS 
		SELECT PDATE AS DATE, PREDCASES, ACTCASES
		FROM 
		(SELECT DATE AS PDATE, CUMULATIVE_CASE_COUNT AS PREDCASES, E_N, R_N, S_N, I_N 
		FROM FIT_PRED 
		WHERE _TYPE_="PREDICT")
		PRED 
		INNER JOIN 
		(SELECT DATE AS ADATE, CUMULATIVE_CASE_COUNT AS ACTCASES, E_N, R_N, S_N, I_N 
		FROM FIT_PRED WHERE _TYPE_="ACTUAL")
		ACT 
		ON PDATE = ADATE;
QUIT;

DATA PLOTFIT;
	SET PLOTFIT  END=LAST;
	PNEWCASES = PREDCASES - LAG(PREDCASES);
	ANEWCASES = ACTCASES - LAG(ACTCASES);
	LABEL PNEWCASES='Daily New Cases';
	LABEL ANEWCASES='Daily New Cases';
	IF LAST THEN CALL SYMPUTX("ENDFIT",PUT(DATE,MMDDYY.));;
RUN;

/*Plot results*/
PROC SGPLOT DATA=PLOTFIT;
	TITLE "Actual v. Predicted New Infections in Region";
	TITLE2 "Initial Reproductive Number (R0): %SYSFUNC(round(&R0_FIT.,.01))";
	TITLE3 "Social Distancing Increased to %SYSFUNC(round(%SYSEVALF(&SOC_DIST_FIT.*100)))% between %sysfunc(INPUTN(&CURVEBENDSTART., date10.), date9.) and %sysfunc(INPUTN(&CURVEBENDSTOP., date10.), date9.)";
	TITLE4 "Adjusted Reproductive Number: %SYSFUNC(round(&R0_BEND_FIT.,.01))";	SERIES X=DATE Y=PNEWCASES / LINEATTRS=(THICKNESS=2)  MARKERS NAME="cases";
	SERIES X=DATE Y=ANEWCASES / LINEATTRS=(THICKNESS=2)  MARKERS NAME="cases";
	FORMAT PNEWCASES ANEWCASES COMMA10.;
RUN;
TITLE;TITLE2;TITLE3;TITLE4;

/* DATA FOR PROC TMODEL APPROACHES */
DATA DINIT(Label="Initial Conditions of Simulation"); 
	FORMAT DATE DATE9.; 
	DO TIME = 0 TO &N_DAYS.; 
		S_N = &Population. - (&I. / &DiagnosedRate.) - &InitRecovered.;
		E_N = &E.;
		I_N = &I0.;
		R_N = &InitRecovered.;
/*		R0  = &R_T.;*/
		DATE = &DAY_ZERO. + TIME;
		OUTPUT; 
	END; 
RUN;

PROC TMODEL DATA=DINIT MODEL=SEIRMOD_I_SMOOTH /*NOPRINT*/;
	SOLVE S_N E_N I_N R_N / SIMULATE TIME=TIME OUT=TMODEL_SEIR_SIM_FIT_I 
                /*RANDOM=25 QUASI=SOBOL ESTDATA=MCCOV SDATA=S*/
	;
QUIT;

%MACRO POSTPROCESS;
	DATA TMODEL_SEIR_SIM_FIT_I;
		FORMAT ModelType $30. DATE ADMIT_DATE DATE9.;
		ModelType="SEIR with PROC (T)MODEL-Fit R0";
		FORMAT ScenarioName $50. ScenarioNameUnique $100. ScenarioSource $10. ScenarioUser $25.;
		ScenarioName="&Scenario.";
		ScenarioIndex=&ScenarioIndex.;
		ScenarioUser="&SYSUSERID.";
		ScenarioSource="&ScenarioSource.";
		ScenarioNameUnique=cats("&Scenario.",' (',ScenarioIndex,'-',"&SYSUSERID.",'-',"&ScenarioSource.",')');
		RETAIN counter cumulative_sum_fatality cumulative_Sum_Market_Fatality;
		SET TMODEL_SEIR_SIM_FIT_I(RENAME=(TIME=DAY /*BETAv=BETA*/) DROP=_ERRORS_ _MODE_ _TYPE_ /*BETA*/);
		DAY = round(DAY,1);
		*WHERE SIGMAfraction=1 and RECOVERYDAYSfraction=1 and SOCIALDfraction=0;
		BY DATE;
		IF first.DATE THEN counter = 1;
			ELSE counter + 1;
		/* START: Common Post-Processing Across each Model Type and Approach */
/*		RT = BETA / GAMMA * &Population.;*/
		NEWINFECTED=LAG&IncubationPeriod(SUM(LAG(SUM(S_N,E_N)),-1*SUM(S_N,E_N)));
		IF counter < &IncubationPeriod THEN NEWINFECTED = .;
		IF NEWINFECTED < 0 THEN NEWINFECTED=0;

		HOSP = CEIL(NEWINFECTED * &HOSP_RATE. * &MarketSharePercent.);
		ICU = CEIL(NEWINFECTED * &ICU_RATE. * &MarketSharePercent. * &HOSP_RATE.);
		VENT = CEIL(NEWINFECTED * &VENT_RATE. * &MarketSharePercent. * &HOSP_RATE.);
		ECMO = CEIL(NEWINFECTED * &ECMO_RATE. * &MarketSharePercent. * &HOSP_RATE.);
		DIAL = CEIL(NEWINFECTED * &DIAL_RATE. * &MarketSharePercent. * &HOSP_RATE.);
					
		Fatality = CEIL(NEWINFECTED * &FatalityRate * &MarketSharePercent. * &HOSP_RATE.);
			Cumulative_sum_fatality + Fatality;
			Deceased_Today = Fatality;
			Total_Deaths = Cumulative_sum_fatality;
					
		MARKET_HOSP = CEIL(NEWINFECTED * &HOSP_RATE.);
		MARKET_ICU = CEIL(NEWINFECTED * &ICU_RATE. * &HOSP_RATE.);
		MARKET_VENT = CEIL(NEWINFECTED * &VENT_RATE. * &HOSP_RATE.);
		MARKET_ECMO = CEIL(NEWINFECTED * &ECMO_RATE. * &HOSP_RATE.);
		MARKET_DIAL = CEIL(NEWINFECTED * &DIAL_RATE. * &HOSP_RATE.);
					
		Market_Fatality = CEIL(NEWINFECTED * &FatalityRate. * &HOSP_RATE.);
			cumulative_Sum_Market_Fatality + Market_Fatality;
			Market_Deceased_Today = Market_Fatality;
			Market_Total_Deaths = cumulative_Sum_Market_Fatality;

		/* setup LOS macro variables */	
		%LET los_varlist = HOSP ICU VENT ECMO DIAL;
			%DO j = 1 %TO %sysfunc(countw(&los_varlist));
				%LET los_curvar = %scan(&los_varlist,&j)_LOS;
				%LET los_len = %sysfunc(countw(&&&los_curvar,:));
				/* the user input a range or rates for LOS = 1, 2, ... */
				%IF &los_len > 1 %THEN %DO;

					%LET &los_curvar._TABLE = %scan(&&&los_curvar,1,:);
					%DO k = 2 %TO &los_len;
						%LET &los_curvar._TABLE = &&&los_curvar._TABLE,%scan(&&&los_curvar,&k,:);
					%END;
					%LET MARKET_&los_curvar._TABLE = &&&los_curvar._TABLE;
					%LET &los_curvar._MAX = &los_len;
					%LET MARKET_&los_curvar._MAX = &los_len;
				%END;
				/* the user input an integer value for LOS */
				%ELSE %DO;
					%LET MARKET_&los_curvar = &&&los_curvar;
					%IF &&&los_curvar = 1 %THEN %LET &los_curvar._TABLE = 1;
					%ELSE %LET &los_curvar._TABLE = 0;
						%DO k = 2 %TO &&&los_curvar;
							%IF &k = &&&los_curvar %THEN %LET &los_curvar._TABLE = &&&los_curvar._TABLE,1;
							%ELSE %LET &los_curvar._TABLE = &&&los_curvar._TABLE,0;
						%END;
					%LET MARKET_&los_curvar._TABLE = &&&los_curvar._TABLE;
					%LET &los_curvar._MAX = &&&los_curvar;
					%LET MARKET_&los_curvar._MAX = &&&los_curvar;
				%END;
				/* %put &los_curvar &&&los_curvar &&&los_curvar._MAX &&&los_curvar._TABLE; */
			%END;

		/* setup drivers for OCCUPANCY variable calculations in this code */
		%LET varlist = HOSP ICU VENT ECMO DIAL MARKET_HOSP MARKET_ICU MARKET_VENT MARKET_ECMO MARKET_DIAL;

		/* *_OCCUPANCY variable calculations */
		call streaminit(2019); /* may need to move to main data step code = as long as it appears before rand function it works correctly */						
		%DO j = 1 %TO %sysfunc(countw(&varlist));
			/* get largest possible LOS for current variable - stored in setup LOS above (increase by 1 in case rates dont sum to exactly 1 */
			%LET maxlos = %eval(%sysfunc(cat(&,%scan(&varlist,&j),_LOS_MAX)) + 1);
			/* arrays to hold an retain the distribution of LOS for hospital census */
				array %scan(&varlist,&j)_los{1:&maxlos} _TEMPORARY_;
			/* at the start of each day reduce the LOS for each patient by 1 day */
				do k = 1 to &maxlos;
					if day = 0 then do;
						%scan(&varlist,&j)_los{k}=0;
					end;
					else do;
						if k < &maxlos then do;
							%scan(&varlist,&j)_los{k} = %scan(&varlist,&j)_los{k+1};
						end;
						else do;
							%scan(&varlist,&j)_los{k} = 0;
						end;
					end;
				end;
			/* distribute todays new admissions by LOS */
				do k = 1 to round(%scan(&varlist,&j),1);
					/*temp = %sysfunc(cat(&,%scan(&varlist,&j),_LOS));*/
					temp = rand('TABLED',%sysfunc(cat(&,%scan(&varlist,&j),_LOS_TABLE)));
					if temp<0 then temp=0;
					else if temp>&maxlos then temp=&maxlos;
					/* if stay (>=1) then put them in the LOS array */
					if temp>0 then %scan(&varlist,&j)_los{temp}+1;
				end;
				/* set the output variables equal to total census for current value of Day */
					%scan(&varlist,&j)_OCCUPANCY = sum(of %scan(&varlist,&j)_los{*});
		%END;
			/* correct name of hospital occupancy to expected output */
				rename HOSP_OCCUPANCY=HOSPITAL_OCCUPANCY MARKET_HOSP_OCCUPANCY=MARKET_HOSPITAL_OCCUPANCY;
			/* derived Occupancy values - calculated from renamed variables so remember to use old name (*hosp) which persist until data is written */
				MedSurgOccupancy=Hosp_Occupancy-ICU_Occupancy;
				Market_MEdSurg_Occupancy=Market_Hosp_Occupancy-MArket_ICU_Occupancy;
		
	/* date variables */
		DATE = &DAY_ZERO. + round(DAY,1);
		ADMIT_DATE = SUM(DATE, &IncubationPeriod.);
		
	/* clean up */
		drop k temp;

/* END: Common Post-Processing Across each Model Type and Approach */
	DROP CUM: counter  /*GAMMA BETAChange:*/;
RUN;

%MEND POSTPROCESS;

%POSTPROCESS;

PROC SGPLOT DATA=work.TMODEL_SEIR_SIM_FIT_I;
	TITLE "Daily Occupancy - PROC TMODEL SEIR Fit Approach";
	TITLE2 "Scenario: &Scenario., Initial Observed Reproductive Number (R0): %SYSFUNC(round(&R0_FIT.,.01))";
	TITLE3 "Social Distancing Increased to %SYSFUNC(round(%SYSEVALF(&SOC_DIST_FIT.*100)))% between %sysfunc(INPUTN(&CURVEBENDSTART., date10.), date9.) and %sysfunc(INPUTN(&CURVEBENDSTOP., date10.), date9.)";
	TITLE4 "Adjusted Reproductive Number: %SYSFUNC(round(&R0_BEND_FIT.,.01))";
	SERIES X=DATE Y=HOSPITAL_OCCUPANCY / LINEATTRS=(THICKNESS=2);
	SERIES X=DATE Y=ICU_OCCUPANCY / LINEATTRS=(THICKNESS=2);
	SERIES X=DATE Y=VENT_OCCUPANCY / LINEATTRS=(THICKNESS=2);
	SERIES X=DATE Y=ECMO_OCCUPANCY / LINEATTRS=(THICKNESS=2);
	SERIES X=DATE Y=DIAL_OCCUPANCY / LINEATTRS=(THICKNESS=2);
	XAXIS LABEL="Date";
	YAXIS LABEL="Daily Occupancy";
RUN;
TITLE; TITLE2; TITLE3;TITLE4;

PROC SGPLOT DATA=work.TMODEL_SEIR_SIM_FIT_I;
	TITLE "Population Compartments - PROC TMODEL SEIR Fit Approach";
	TITLE2 "Scenario: &Scenario., Initial Observed Reproductive Number (R0): %SYSFUNC(round(&R0_FIT.,.01))";
	TITLE3 "Social Distancing Increased to %SYSFUNC(round(%SYSEVALF(&SOC_DIST_FIT.*100)))% between %sysfunc(INPUTN(&CURVEBENDSTART., date10.), date9.) and %sysfunc(INPUTN(&CURVEBENDSTOP., date10.), date9.)";
	TITLE4 "Adjusted Reproductive Number: %SYSFUNC(round(&R0_BEND_FIT.,.01))";
	SERIES X=DATE Y=S_N / LINEATTRS=(THICKNESS=2);
	SERIES X=DATE Y=E_N / LINEATTRS=(THICKNESS=2);
	SERIES X=DATE Y=I_N / LINEATTRS=(THICKNESS=2);
	SERIES X=DATE Y=R_N / LINEATTRS=(THICKNESS=2);
	XAXIS LABEL="Date";
	YAXIS LABEL="Population Compartments";
RUN;
TITLE; TITLE2; TITLE3;TITLE4;







			DATA TMODEL_SEIR_FIT_SOLVE;
					FORMAT ModelType $30. Scenarioname $30. DATE ADMIT_DATE DATE9.;
					ModelType="TMODEL - SEIR - OHIO FIT";
					ScenarioName="&Scenario.";
/*					ScenarioIndex=&ScenarioIndex.;*/
/*					ScenarionNameUnique=cats("&Scenario.",' (',ScenarioIndex,')');*/
					LABEL HOSPITAL_OCCUPANCY="Hospital Occupancy" ICU_OCCUPANCY="ICU Occupancy" VENT_OCCUPANCY="Ventilator Utilization"
						ECMO_OCCUPANCY="ECMO Utilization" DIAL_OCCUPANCY="Dialysis Utilization";
					RETAIN LAG_S LAG_I LAG_R LAG_N CUMULATIVE_SUM_HOSP CUMULATIVE_SUM_ICU CUMULATIVE_SUM_VENT CUMULATIVE_SUM_ECMO CUMULATIVE_SUM_DIAL Cumulative_sum_fatality
						CUMULATIVE_SUM_MARKET_HOSP CUMULATIVE_SUM_MARKET_ICU CUMULATIVE_SUM_MARKET_VENT CUMULATIVE_SUM_MARKET_ECMO CUMULATIVE_SUM_MARKET_DIAL cumulative_Sum_Market_Fatality;
					LAG_S = S_N; 
					LAG_E = E_N; 
					LAG_I = I_N; 
					LAG_R = R_N; 
					LAG_N = N; 
					SET TMODEL_SEIR_FIT_SOLVE(RENAME=(TIME=DAY) DROP=_ERRORS_ _MODE_ _TYPE_);
					N = SUM(S_N, E_N, I_N, R_N);
					SCALE = LAG_N / N;
				/* START: Common Post-Processing Across each Model Type and Approach */
					NEWINFECTED=LAG&IncubationPeriod(SUM(LAG(SUM(S_N,E_N)),-1*SUM(S_N,E_N)));
					IF NEWINFECTED < 0 THEN NEWINFECTED=0;
					HOSP = NEWINFECTED * &HOSP_RATE. * &MarketSharePercent.;
					ICU = NEWINFECTED * &ICU_RATE. * &MarketSharePercent. * &HOSP_RATE.;
					VENT = NEWINFECTED * &VENT_RATE. * &MarketSharePercent. * &HOSP_RATE.;
					ECMO = NEWINFECTED * &ECMO_RATE. * &MarketSharePercent. * &HOSP_RATE.;
					DIAL = NEWINFECTED * &DIAL_RATE. * &MarketSharePercent. * &HOSP_RATE.;
					Fatality = NEWINFECTED * &FatalityRate * &MarketSharePercent. * &HOSP_RATE.;
					MARKET_HOSP = NEWINFECTED * &HOSP_RATE.;
					MARKET_ICU = NEWINFECTED * &ICU_RATE. * &HOSP_RATE.;
					MARKET_VENT = NEWINFECTED * &VENT_RATE. * &HOSP_RATE.;
					MARKET_ECMO = NEWINFECTED * &ECMO_RATE. * &HOSP_RATE.;
					MARKET_DIAL = NEWINFECTED * &DIAL_RATE. * &HOSP_RATE.;
					Market_Fatality = NEWINFECTED * &FatalityRate. * &HOSP_RATE.;
					CUMULATIVE_SUM_HOSP + HOSP;
					CUMULATIVE_SUM_ICU + ICU;
					CUMULATIVE_SUM_VENT + VENT;
					CUMULATIVE_SUM_ECMO + ECMO;
					CUMULATIVE_SUM_DIAL + DIAL;
					Cumulative_sum_fatality + Fatality;
					CUMULATIVE_SUM_MARKET_HOSP + MARKET_HOSP;
					CUMULATIVE_SUM_MARKET_ICU + MARKET_ICU;
					CUMULATIVE_SUM_MARKET_VENT + MARKET_VENT;
					CUMULATIVE_SUM_MARKET_ECMO + MARKET_ECMO;
					CUMULATIVE_SUM_MARKET_DIAL + MARKET_DIAL;
					cumulative_Sum_Market_Fatality + Market_Fatality;
					CUMADMITLAGGED=ROUND(LAG&HOSP_LOS.(CUMULATIVE_SUM_HOSP),1) ;
					CUMICULAGGED=ROUND(LAG&ICU_LOS.(CUMULATIVE_SUM_ICU),1) ;
					CUMVENTLAGGED=ROUND(LAG&VENT_LOS.(CUMULATIVE_SUM_VENT),1) ;
					CUMECMOLAGGED=ROUND(LAG&ECMO_LOS.(CUMULATIVE_SUM_ECMO),1) ;
					CUMDIALLAGGED=ROUND(LAG&DIAL_LOS.(CUMULATIVE_SUM_DIAL),1) ;
					CUMMARKETADMITLAG=ROUND(LAG&HOSP_LOS.(CUMULATIVE_SUM_MARKET_HOSP));
					CUMMARKETICULAG=ROUND(LAG&ICU_LOS.(CUMULATIVE_SUM_MARKET_ICU));
					CUMMARKETVENTLAG=ROUND(LAG&VENT_LOS.(CUMULATIVE_SUM_MARKET_VENT));
					CUMMARKETECMOLAG=ROUND(LAG&ECMO_LOS.(CUMULATIVE_SUM_MARKET_ECMO));
					CUMMARKETDIALLAG=ROUND(LAG&DIAL_LOS.(CUMULATIVE_SUM_MARKET_DIAL));
					ARRAY FIXINGDOT _NUMERIC_;
					DO OVER FIXINGDOT;
						IF FIXINGDOT=. THEN FIXINGDOT=0;
					END;
					HOSPITAL_OCCUPANCY= ROUND(CUMULATIVE_SUM_HOSP-CUMADMITLAGGED,1);
					ICU_OCCUPANCY= ROUND(CUMULATIVE_SUM_ICU-CUMICULAGGED,1);
					VENT_OCCUPANCY= ROUND(CUMULATIVE_SUM_VENT-CUMVENTLAGGED,1);
					ECMO_OCCUPANCY= ROUND(CUMULATIVE_SUM_ECMO-CUMECMOLAGGED,1);
					DIAL_OCCUPANCY= ROUND(CUMULATIVE_SUM_DIAL-CUMDIALLAGGED,1);
					Deceased_Today = Fatality;
					Total_Deaths = Cumulative_sum_fatality;
					MedSurgOccupancy=Hospital_Occupancy-ICU_Occupancy;
					MARKET_HOSPITAL_OCCUPANCY= ROUND(CUMULATIVE_SUM_MARKET_HOSP-CUMMARKETADMITLAG,1);
					MARKET_ICU_OCCUPANCY= ROUND(CUMULATIVE_SUM_MARKET_ICU-CUMMARKETICULAG,1);
					MARKET_VENT_OCCUPANCY= ROUND(CUMULATIVE_SUM_MARKET_VENT-CUMMARKETVENTLAG,1);
					MARKET_ECMO_OCCUPANCY= ROUND(CUMULATIVE_SUM_MARKET_ECMO-CUMMARKETECMOLAG,1);
					MARKET_DIAL_OCCUPANCY= ROUND(CUMULATIVE_SUM_MARKET_DIAL-CUMMARKETDIALLAG,1);	
					Market_Deceased_Today = Market_Fatality;
					Market_Total_Deaths = cumulative_Sum_Market_Fatality;
					Market_MEdSurg_Occupancy=Market_Hospital_Occupancy-MArket_ICU_Occupancy;
					DATE = &DAY_ZERO. + DAY;
					ADMIT_DATE = SUM(DATE, &IncubationPeriod.);
				/* END: Common Post-Processing Across each Model Type and Approach */
/*					DROP LAG: CUM: ;*/
				RUN;


/*Retired - Point Change Method*/
				PROC MODEL DATA = STORE.FIT_INPUT(WHERE=(DATE>"14FEB2020"D)) OUTMODEL=SEIRMOD_I /*NOPRINT*/; 
					/* Parameters of interest */
					PARMS R0 &R_T. I0 &I. RI -1 DI &ISOChangeDate1.;
					BOUNDS 1 <= R0 <= 13;
					RESTRICT RI + R0 > 0;
					/* Fixed values */
					N = &Population.;
					INF = &RecoveryDays.;
					SIGMAINV = &SIGMAINV.;
					STEP = CDF('NORMAL',DATE, DI, 1);/*Fit variance*/
					/* Differential equations */
					GAMMA = 1 / INF;
					BETA = (R0 + RI*STEP) * GAMMA / N;/*R0*(1-STEP)*/
					/* Differential equations */
					/* a. Decrease in healthy susceptible persons through infections: number of encounters of (S,I)*TransmissionProb*/
					DERT.S_N = -BETA * S_N * I_N;
					/* b. inflow from a. -Decrease in Exposed: alpha*e "promotion" inflow from E->I;*/
					DERT.E_N = BETA * S_N * I_N - SIGMAINV * E_N;
					/* c. inflow from b. - outflow through recovery or death during illness*/
					DERT.I_N = SIGMAINV * E_N - GAMMA * I_N;
					/* d. Recovered and death humans through "promotion" inflow from c.*/
					DERT.R_N = GAMMA * I_N;
					CUMULATIVE_CASE_COUNT = I_N + R_N;
					/* Fit the data */
					FIT CUMULATIVE_CASE_COUNT INIT=(S_N=&Population. E_N=0 I_N=I0 R_N=0) / TIME=TIME DYNAMIC OUTPREDICT OUTACTUAL OUT=FIT_PRED LTEBOUND=1E-10 OUTEST=FIT_PARMS;
/*						%IF &HAVE_V151. = YES %THEN %DO; OPTIMIZER=ORMP(OPTTOL=1E-5) %END;;*/
					OUTVARS S_N E_N I_N R_N;
				QUIT;

				PROC SQL NOPRINT;
					SELECT R0 INTO :R0_FIT FROM FIT_PARMS;
					SELECT "'"||PUT(DI,DATE9.)||"'"||"D" INTO :CURVEBEND1 FROM FIT_PARMS;
					SELECT SUM(R0,RI) INTO :R0_BEND_FIT FROM FIT_PARMS;
				QUIT;

				%LET SOC_DIST_FIT = %SYSEVALF(1 - &R0_BEND_FIT / &R0_FIT);
				%PUT CURVEBEND1 = &CURVEBEND1;
				%PUT R0_FIT = &R0_FIT;
				%PUT R0_BEND_FIT = &R0_BEND_FIT;
				%PUT SOC_DIST_FIT = &SOC_DIST_FIT;

				DATA FIT_PRED;
						SET FIT_PRED;
						LABEL CUMULATIVE_CASE_COUNT='Cumulative Incidence';
						FORMAT DATE DATE9.; 
						DATE = &FIRST_CASE. + TIME -1;
				run;
				PROC SGPLOT DATA=FIT_PRED;
						WHERE _TYPE_  NE 'RESIDUAL';
						TITLE "Actual v. Predicted Infections in Region";
						TITLE2 "Initial R0: %SYSFUNC(round(&R0_FIT.,.01))";
						TITLE3 "Adjusted R0 after %sysfunc(INPUTN(&CURVEBEND1., date10.), date9.): %SYSFUNC(round(&R0_BEND_FIT.,.01)) with Social Distancing of %SYSFUNC(round(%SYSEVALF(&SOC_DIST_FIT.*100)))%";
						SERIES X=DATE Y=CUMULATIVE_CASE_COUNT / LINEATTRS=(THICKNESS=2) GROUP=_TYPE_  MARKERS NAME="cases";
						FORMAT CUMULATIVE_CASE_COUNT COMMA10.;
				RUN;
				TITLE;TITLE2;TITLE3;
