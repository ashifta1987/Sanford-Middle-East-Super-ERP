import { useTranslation } from 'react-i18next';

export function LanguageToggle() {
  const { t, i18n } = useTranslation();
  const next = i18n.language === 'ar' ? 'en' : 'ar';
  return (
    <button
      type="button"
      onClick={() => i18n.changeLanguage(next)}
      aria-label={`${t('top.language')}: ${next === 'ar' ? 'العربية' : 'English'}`}
      className="min-h-[44px] rounded-btn border border-line bg-white px-3 text-[15px] font-medium hover:bg-page"
    >
      {i18n.language === 'ar' ? 'ع · EN' : 'EN · ع'}
    </button>
  );
}
