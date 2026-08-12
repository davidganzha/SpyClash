import React, { useState } from 'react';
import { useAuth } from '@/lib/AuthContext';
import { useLanguage } from '@/components/LanguageContext';
import { localize } from '@/components/i18n';

const UserNotRegisteredError = () => {
  const { checkAppState, logout } = useAuth();
  const { lang } = useLanguage();
  const [retrying, setRetrying] = useState(false);

  const retry = async () => {
    setRetrying(true);
    try {
      await checkAppState();
    } finally {
      setRetrying(false);
    }
  };

  return (
    <div className="flex flex-col items-center justify-center min-h-screen bg-gradient-to-b from-white to-slate-50">
      <div className="max-w-md w-full p-8 bg-white rounded-lg shadow-lg border border-slate-100">
        <div className="text-center">
          <div className="inline-flex items-center justify-center w-16 h-16 mb-6 rounded-full bg-orange-100">
            <svg className="w-8 h-8 text-orange-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>
          </div>
          <h1 className="text-3xl font-bold text-slate-900 mb-4">{localize(lang, "Access Restricted", "Доступ ограничен", "Доступ обмежено")}</h1>
          <p className="text-slate-600 mb-8">
            {localize(lang, "You are not registered to use this application. Please contact the app administrator to request access.", "Вы не зарегистрированы для использования этого приложения. Свяжитесь с администратором, чтобы запросить доступ.", "Ви не зареєстровані для використання цього застосунку. Зверніться до адміністратора, щоб отримати доступ.")}
          </p>
          <div className="p-4 bg-slate-50 rounded-md text-sm text-slate-600">
            <p>{localize(lang, "If you believe this is an error, you can:", "Если вы считаете, что это ошибка:", "Якщо ви вважаєте, що це помилка:")}</p>
            <ul className="list-disc list-inside mt-2 space-y-1">
              <li>{localize(lang, "Verify you are logged in with the correct account", "Убедитесь, что вошли в нужный аккаунт", "Переконайтеся, що ввійшли до потрібного облікового запису")}</li>
              <li>{localize(lang, "Contact the app administrator for access", "Свяжитесь с администратором для получения доступа", "Зверніться до адміністратора, щоб отримати доступ")}</li>
              <li>{localize(lang, "Try logging out and back in again", "Попробуйте выйти и войти снова", "Спробуйте вийти й увійти знову")}</li>
            </ul>
          </div>
          <div className="mt-6 flex flex-col gap-3">
            <button
              type="button"
              onClick={retry}
              disabled={retrying}
              className="w-full px-4 py-3 bg-red-600 text-white font-semibold disabled:opacity-60"
            >
              {retrying
                ? localize(lang, 'RETRYING…', 'ПОВТОРНАЯ ПОПЫТКА…', 'ПОВТОРНА СПРОБА…')
                : localize(lang, 'RETRY ACCESS', 'ПОВТОРИТЬ ДОСТУП', 'ПОВТОРИТИ ДОСТУП')}
            </button>
            <button
              type="button"
              onClick={() => logout(true)}
              className="w-full px-4 py-3 border border-slate-300 text-slate-700 font-semibold"
            >
              {localize(lang, 'USE ANOTHER ACCOUNT', 'ИСПОЛЬЗОВАТЬ ДРУГОЙ АККАУНТ', 'ВИКОРИСТАТИ ІНШИЙ ОБЛІКОВИЙ ЗАПИС')}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default UserNotRegisteredError;
