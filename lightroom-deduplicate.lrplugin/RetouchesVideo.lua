-- hasAdjustments inclut les bornes TrimStart/TrimEnd initiales des vidéos.
-- Seuls des réglages effectivement lus et reconnus neutres permettent de
-- conclure « non retouchée ». Un champ inconnu demande une vérification.
local M = {}
local T = require('Langue').t
-- Profils vierges lus dans Lightroom 15.6 avant/après matérialisation des
-- paramètres (tests/video-vierge-lr15.lua). Les contrôles inactifs peuvent
-- avoir des valeurs non nulles ; un nouveau paramètre exige une vérification.
local neutres = {
  ColorGradeBlending=50, ColorNoiseReductionDetail=50, ColorNoiseReductionSmoothness=50,
  ConvertToGrayscale=false, CurveRefineSaturation=100,
  DefringeGreenHueHi=60, DefringeGreenHueLo=40, DefringePurpleHueHi=70, DefringePurpleHueLo=30,
  GlowRange=50, GlowSpread=50, GrainFrequency=50, GrainSize=25, HDRMaxValue=2.3,
  LensProfileSetup='LensDefaults', LuminanceNoiseReductionDetail=50, OverrideLookVignette=false,
  ParametricHighlightSplit=75, ParametricMidtoneSplit=50, ParametricShadowSplit=25,
  PerspectiveScale=100, PostCropVignetteFeather=50, PostCropVignetteMidpoint=50,
  PostCropVignetteStyle=1, SharpenDetail=25, SharpenRadius=1, ToneCurveName2012='Linear',
  UprightCenterNormX=0.5, UprightCenterNormY=0.5, UprightFocalLength35mm=35,
  UprightPreview=false, UprightTransformCount=6, UprightVersion=151388160,
  VignetteMidpoint=50, WhiteBalance='As Shot', CameraProfile='Embedded',
  AutoExposure=false, AutoBrightness=false, AutoContrast=false, AutoShadows=false,
  CropTop=0, CropLeft=0, CropBottom=1, CropRight=1, CropAngle=0,
  CropConstrainToWarp=0, CropConstrainToUnitSquare=1, ToneMapStrength=0,
}
local zeros = [[
AutoLateralCA Blacks2012 BlueHue BlueSaturation Brightness ChromaticAberrationB ChromaticAberrationR
Clarity Clarity2012 ColorGradeGlobalHue ColorGradeGlobalLum ColorGradeGlobalSat ColorGradeHighlightLum
ColorGradeMidtoneHue ColorGradeMidtoneLum ColorGradeMidtoneSat ColorGradeShadowLum ColorNoiseReduction
Contrast Contrast2012 Defringe DefringeGreenAmount DefringePurpleAmount Dehaze Exposure Exposure2012
FillLight Glow GlowStyle GlowWarmth GrainAmount GreenHue GreenSaturation HDREditMode HighlightRecovery
Highlights2012 HueAdjustmentAqua HueAdjustmentBlue HueAdjustmentGreen HueAdjustmentMagenta HueAdjustmentOrange
HueAdjustmentPurple HueAdjustmentRed HueAdjustmentYellow IncrementalTemperature IncrementalTint
LensManualDistortionAmount LensProfileEnable LuminanceAdjustmentAqua LuminanceAdjustmentBlue
LuminanceAdjustmentGreen LuminanceAdjustmentMagenta LuminanceAdjustmentOrange LuminanceAdjustmentPurple
LuminanceAdjustmentRed LuminanceAdjustmentYellow LuminanceNoiseReductionContrast LuminanceSmoothing
ParametricDarks ParametricHighlights ParametricLights ParametricShadows PerspectiveAspect PerspectiveHorizontal
PerspectiveRotate PerspectiveUpright PerspectiveVertical PerspectiveX PerspectiveY PostCropVignetteAmount
PostCropVignetteHighlightContrast PostCropVignetteRoundness RedHue RedSaturation SDRBlend SDRBrightness
SDRClarity SDRContrast SDRHighlights SDRShadows SDRWhites Saturation SaturationAdjustmentAqua
SaturationAdjustmentBlue SaturationAdjustmentGreen SaturationAdjustmentMagenta SaturationAdjustmentOrange
SaturationAdjustmentPurple SaturationAdjustmentRed SaturationAdjustmentYellow ShadowTint Shadows Shadows2012
SharpenEdgeMasking Sharpness SplitToningBalance SplitToningHighlightHue SplitToningHighlightSaturation
SplitToningShadowHue SplitToningShadowSaturation Texture UprightCenterMode UprightFocalMode
UprightFourSegmentsCount Vibrance VignetteAmount Whites2012
]]
for cle in zeros:gmatch('%S+') do neutres[cle]=0 end
for cle in ([[EnableCalibration EnableColorAdjustments EnableDetail EnableDistractionRemoval EnableEffects
EnableGrayscaleMix EnableLensCorrections EnableMaskGroupBasedCorrections EnableRedEye EnableRetouch
EnableSplitToning EnableTransform]]):gmatch('%S+') do neutres[cle]=true end
for _,cle in ipairs({'AILook','LensBlur','PointColors','RedEyeInfo','RetouchInfo','FilterList','MaskGroupBasedCorrections'}) do
  neutres[cle]={}
end
for _,cle in ipairs({'ToneCurvePV2012','ToneCurvePV2012Blue','ToneCurvePV2012Green','ToneCurvePV2012Red'}) do
  neutres[cle]={0,0,255,255}
end
local function fini(v) return type(v)=='number' and v==v and v>-math.huge and v<math.huge end
local function secondes(r)
  if type(r)~='table' or not fini(r.numerator) or not fini(r.denominator) or r.denominator<=0 then return nil end
  local v=r.numerator/r.denominator
  return fini(v) and v or nil
end
local function egaux(a,b)
  if type(a)~=type(b) then return false end
  if type(b)~='table' then return a==b end
  for k,v in pairs(b) do if a[k]~=v then return false end end
  for k in pairs(a) do if b[k]==nil then return false end end
  return true
end
-- Renvoie false (vierge), true (coupe ou réglage), ou nil et une raison si
-- la lecture ne permet pas de décider. Les durées du SDK sont non formatées.
function M.etat(reglages,meta)
  if type(reglages)~='table' then return nil,T('réglages vidéo illisibles', 'unreadable video settings') end
  meta=meta or {}
  local duree,tronquee=meta.durationInSeconds,meta.trimmedDurationInSeconds
  local debut,fin=secondes(reglages.TrimStart),secondes(reglages.TrimEnd)
  if not fini(duree) or duree<=0 or not fini(tronquee) or tronquee<=0 or not debut or not fin then
    return nil,T('bornes ou durées vidéo indisponibles', 'video trim points or durations unavailable')
  end
  if math.abs(debut)>1e-7 or math.abs(fin-duree)>1e-7 or math.abs(tronquee-duree)>1e-7 then
    return true,T('coupe vidéo', 'video trim')
  end
  for _,cle in ipairs({'Saturation','Vibrance','WhiteBalance'}) do
    if reglages[cle]==nil then return nil,T('réglages vidéo incomplets : ', 'incomplete video settings: ')..cle end
  end
  if reglages.Exposure==nil and reglages.Exposure2012==nil then return nil,T('exposition vidéo indisponible', 'video exposure unavailable') end
  if reglages.Contrast==nil and reglages.Contrast2012==nil then return nil,T('contraste vidéo indisponible', 'video contrast unavailable') end
  for cle,valeur in pairs(reglages) do
    if cle=='ProcessVersion' then
      if type(valeur)~='string' or valeur=='' then return nil,T('version de traitement vidéo inconnue', 'unknown video process version') end
    elseif cle~='TrimStart' and cle~='TrimEnd' then
      if neutres[cle]==nil then return nil,T('réglage vidéo inconnu : ', 'unknown video setting: ')..tostring(cle) end
      if not egaux(valeur,neutres[cle]) then return true,T('réglage vidéo : ', 'video setting: ')..cle end
    end
  end
  return false
end
return M
