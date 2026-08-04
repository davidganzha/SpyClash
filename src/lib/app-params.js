import {
	isProductionAppOrigin,
	resolveAppBaseUrl,
	resolveAppId,
	resolveFunctionsVersion,
} from "./appParamsPolicy.js";

const isNode = typeof window === 'undefined';
const memoryStorage = (() => {
	const values = new Map();
	return {
		getItem: (key) => values.get(key) ?? null,
		setItem: (key, value) => values.set(key, String(value)),
		removeItem: (key) => values.delete(key),
	};
})();
const windowObj = isNode ? { localStorage: memoryStorage } : window;
const storage = windowObj.localStorage;

const consumeClearAccessTokenFlag = () => {
	if (isNode) return;

	const url = new URL(window.location.href);
	const shouldClear = url.searchParams.get('clear_access_token') === 'true';

	// Older builds accidentally persisted this flag, causing every reload to
	// delete a freshly issued OAuth token. Always remove the stale key.
	storage.removeItem('base44_clear_access_token');

	if (!shouldClear) return;

	storage.removeItem('base44_access_token');
	storage.removeItem('token');
	url.searchParams.delete('clear_access_token');
	window.history.replaceState({}, document.title, `${url.pathname}${url.search}${url.hash}`);
};

const toSnakeCase = (str) => {
	return str.replace(/([A-Z])/g, '_$1').toLowerCase();
}

const getAppParamValue = (paramName, { defaultValue = undefined, removeFromUrl = false } = {}) => {
	if (isNode) {
		return defaultValue;
	}
	const storageKey = `base44_${toSnakeCase(paramName)}`;
	const urlParams = new URLSearchParams(window.location.search);
	const searchParam = urlParams.get(paramName);
	if (removeFromUrl) {
		urlParams.delete(paramName);
		const newUrl = `${window.location.pathname}${urlParams.toString() ? `?${urlParams.toString()}` : ""
			}${window.location.hash}`;
		window.history.replaceState({}, document.title, newUrl);
	}
	if (searchParam) {
		storage.setItem(storageKey, searchParam);
		return searchParam;
	}
	if (defaultValue) {
		storage.setItem(storageKey, defaultValue);
		return defaultValue;
	}
	const storedValue = storage.getItem(storageKey);
	if (storedValue) {
		return storedValue;
	}
	return null;
}

const getFunctionsVersion = () => {
	if (isNode) return undefined;

	const storageKey = 'base44_functions_version';
	const urlValue = new URLSearchParams(window.location.search).get('functions_version');
	const productionOrigin = isProductionAppOrigin(window.location);
	const resolution = resolveFunctionsVersion({
		urlValue,
		environmentValue: import.meta.env.VITE_BASE44_FUNCTIONS_VERSION,
		storedValue: storage.getItem(storageKey),
		productionOrigin,
	});

	if (resolution.clearStored) storage.removeItem(storageKey);
	if (resolution.persist && resolution.value) storage.setItem(storageKey, resolution.value);
	return resolution.value;
};

const getAppId = () => {
	const storageKey = 'base44_app_id';
	const productionOrigin = !isNode && isProductionAppOrigin(window.location);
	const resolution = resolveAppId({
		urlValue: isNode ? null : new URLSearchParams(window.location.search).get('app_id'),
		environmentValue: import.meta.env.VITE_BASE44_APP_ID,
		storedValue: storage.getItem(storageKey),
		productionOrigin,
	});

	if (resolution.clearStored) storage.removeItem(storageKey);
	if (resolution.persist && resolution.value) storage.setItem(storageKey, resolution.value);
	return resolution.value;
};

const getAppBaseUrl = () => {
	const storageKey = 'base44_app_base_url';
	const productionOrigin = !isNode && isProductionAppOrigin(window.location);
	const resolution = resolveAppBaseUrl({
		urlValue: isNode ? null : new URLSearchParams(window.location.search).get('app_base_url'),
		environmentValue: import.meta.env.VITE_BASE44_APP_BASE_URL,
		storedValue: storage.getItem(storageKey),
		productionOrigin,
	});

	if (resolution.clearStored) storage.removeItem(storageKey);
	return resolution.value;
};

const getAppParams = () => {
	consumeClearAccessTokenFlag();
	return {
		appId: getAppId(),
		token: getAppParamValue("access_token", { removeFromUrl: true }),
		fromUrl: getAppParamValue("from_url", { defaultValue: window.location.href }),
		functionsVersion: getFunctionsVersion(),
		appBaseUrl: getAppBaseUrl(),
	}
}


export const appParams = {
	...getAppParams()
}
