import { BadRequestException, ForbiddenException, UnauthorizedException, ValidationPipe } from '@nestjs/common';
import type { ExecutionContext } from '@nestjs/common';
import { GUARDS_METADATA } from '@nestjs/common/constants';
import { FastifyAdapter, NestFastifyApplication } from '@nestjs/platform-fastify';
import { Test } from '@nestjs/testing';
import { AuditAction, AuditResource, Permission } from '@bookorbit/types';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { AUDITABLE_KEY } from '../../common/decorators/auditable.decorator';
import type { AuditableOptions } from '../../common/decorators/auditable.decorator';
import { IS_PUBLIC_KEY } from '../../common/decorators/public.decorator';
import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { BookRequestService } from '../book-request/book-request.service';
import { BookRequestModule } from '../book-request/book-request.module';
import { DownloadClientConfigService } from '../book-request/download-clients/download-client-config.service';
import { RequestFulfillmentService } from '../book-request/fulfillment/request-fulfillment.service';
import { RequestImportService } from '../book-request/fulfillment/request-import.service';
import { RequestVerificationService } from '../book-request/fulfillment/request-verification.service';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderRequestFulfilmentController } from './koreader-request-fulfilment.controller';
import { KoreaderRequestGuard } from './koreader-request.guard';
import { KoreaderModule } from './koreader.module';

const routes = [
  { method: 'GET', path: '/9/releases' },
  { method: 'POST', path: '/9/releases/search', payload: { title: 'Dune', authors: ['Frank Herbert'] } },
  { method: 'POST', path: '/9/releases/inspect', payload: { indexerId: 3, releaseGuid: 'release-guid' } },
  { method: 'GET', path: '/9/download-clients' },
  { method: 'POST', path: '/9/grab', payload: { indexerId: 3, releaseGuid: 'release-guid', downloadClientId: 4 } },
  { method: 'GET', path: '/9/review' },
  { method: 'POST', path: '/9/force-file' },
  { method: 'POST', path: '/9/discard-import' },
  { method: 'POST', path: '/9/downloads/12/select-unit', payload: { unitIndex: 0 } },
  { method: 'POST', path: '/9/downloads/12/cancel' },
] as const;

describe('KOReader request fulfilment routes', () => {
  const base = '/koreader/plugin/requests';
  let app: NestFastifyApplication;
  let user: RequestUser;
  let authenticated: boolean;
  const requests = {
    assertCanFulfil: vi.fn(),
    getOne: vi.fn(),
    cancelDownload: vi.fn(),
  };
  const fulfillment = { listReleases: vi.fn(), inspectRelease: vi.fn(), grab: vi.fn() };
  const downloadClients = { findEnabledSummaries: vi.fn(), findAll: vi.fn() };
  const imports = { importChosenUnit: vi.fn() };
  const verification = { getReview: vi.fn(), fileHeldImport: vi.fn(), discardHeldImport: vi.fn() };
  const downstream = () => [
    requests.getOne,
    requests.cancelDownload,
    ...Object.values(fulfillment),
    ...Object.values(downloadClients),
    ...Object.values(imports),
    ...Object.values(verification),
  ];
  const settled = { id: 9, userId: 42, status: 'available', matchedBookId: 21 };

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [KoreaderRequestFulfilmentController],
      providers: [
        KoreaderRequestGuard,
        PermissionService,
        { provide: BookRequestService, useValue: requests },
        { provide: RequestFulfillmentService, useValue: fulfillment },
        { provide: DownloadClientConfigService, useValue: downloadClients },
        { provide: RequestImportService, useValue: imports },
        { provide: RequestVerificationService, useValue: verification },
      ],
    })
      .overrideGuard(KoreaderAuthGuard)
      .useValue({
        canActivate(context: ExecutionContext) {
          if (!authenticated) throw new UnauthorizedException('Missing KOReader credentials');
          context.switchToHttp().getRequest<{ user: RequestUser }>().user = user;
          return true;
        },
      })
      .compile();
    app = module.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
    app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
    await app.init();
    await app.getHttpAdapter().getInstance().ready();
  });

  afterAll(async () => app.close());
  beforeEach(() => {
    vi.resetAllMocks();
    authenticated = true;
    user = {
      id: 42,
      permissions: [Permission.KoreaderSync, Permission.BookRequestAccess, Permission.BookRequestSelfFulfill],
      isSuperuser: false,
    } as RequestUser;
    requests.assertCanFulfil.mockResolvedValue({ request: { id: 9, userId: 42 } });
    requests.getOne.mockResolvedValue(settled);
    requests.cancelDownload.mockResolvedValue({ id: 9, status: 'approved' });
    fulfillment.listReleases.mockResolvedValue({ releases: [{ indexerId: 3, guid: 'release-guid', title: 'Dune EPUB' }], searchedAt: '2026-11-01' });
    fulfillment.inspectRelease.mockResolvedValue({ files: [{ path: 'Dune.epub', sizeBytes: 100 }] });
    fulfillment.grab.mockResolvedValue({ id: 9, status: 'grabbed' });
    downloadClients.findEnabledSummaries.mockResolvedValue([{ id: 4, name: 'Library downloads', color: null, delivery: 'torrent' }]);
    verification.getReview.mockResolvedValue({ requestId: 9, status: 'needs_review', reasons: ['Check the title'] });
    verification.fileHeldImport.mockResolvedValue(undefined);
    verification.discardHeldImport.mockResolvedValue(undefined);
    imports.importChosenUnit.mockResolvedValue(undefined);
  });

  it('uses KOReader authentication and explicit request permission checks despite bypassing JWT', () => {
    expect(Reflect.getMetadata(IS_PUBLIC_KEY, KoreaderRequestFulfilmentController)).toBe(true);
    expect(Reflect.getMetadata(GUARDS_METADATA, KoreaderRequestFulfilmentController)).toEqual([KoreaderAuthGuard, KoreaderRequestGuard]);
  });

  it('reuses the registered fulfilment providers through the owning module exports', () => {
    const shared = [RequestFulfillmentService, DownloadClientConfigService, RequestImportService, RequestVerificationService];
    expect(Reflect.getMetadata('providers', BookRequestModule)).toEqual(expect.arrayContaining(shared));
    expect(Reflect.getMetadata('exports', BookRequestModule)).toEqual(expect.arrayContaining(shared));
    expect(Reflect.getMetadata('imports', KoreaderModule)).toContain(BookRequestModule);
    expect(Reflect.getMetadata('controllers', KoreaderModule)).toContain(KoreaderRequestFulfilmentController);
  });

  it.each(routes)('requires authentication for $method $path', async (route) => {
    authenticated = false;
    const { path, ...options } = route;
    const response = await app.inject({ ...options, url: base + path });
    expect(response.statusCode).toBe(401);
    expect(requests.assertCanFulfil).not.toHaveBeenCalled();
    expect(downstream().every((mock) => mock.mock.calls.length === 0)).toBe(true);
  });

  it.each(routes)('requires request permission for $method $path', async (route) => {
    user.permissions = [Permission.KoreaderSync, Permission.BookRequestSelfFulfill];
    const { path, ...options } = route;
    const response = await app.inject({ ...options, url: base + path });
    expect(response.statusCode).toBe(403);
    expect(requests.assertCanFulfil).not.toHaveBeenCalled();
    expect(downstream().every((mock) => mock.mock.calls.length === 0)).toBe(true);
  });

  it.each(routes)('checks ownership before any work for $method $path', async (route) => {
    requests.assertCanFulfil.mockRejectedValueOnce(new ForbiddenException('You cannot fulfil this book request'));
    const { path, ...options } = route;
    const response = await app.inject({ ...options, url: base + path });
    expect(response.statusCode).toBe(403);
    expect(requests.assertCanFulfil).toHaveBeenCalledExactlyOnceWith(9, user);
    expect(downstream().every((mock) => mock.mock.calls.length === 0)).toBe(true);
  });

  it.each(routes)('returns successful $method $path responses without caching', async (route) => {
    const { path, ...options } = route;
    const response = await app.inject({ ...options, url: base + path });
    expect(response.statusCode).toBe(200);
    expect(response.headers['cache-control']).toBe('no-store');
    expect(requests.assertCanFulfil).toHaveBeenCalledExactlyOnceWith(9, user);
  });

  it('awaits ownership before asking providers for releases', async () => {
    let allow!: (value: unknown) => void;
    let reached!: () => void;
    const checking = new Promise<void>((resolve) => {
      reached = resolve;
    });
    requests.assertCanFulfil.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          allow = resolve;
          reached();
        }),
    );
    const response = app.inject({ method: 'GET', url: base + '/9/releases' }).then((result) => result);
    await checking;
    expect(fulfillment.listReleases).not.toHaveBeenCalled();
    allow({ request: { id: 9, userId: 42 } });
    expect((await response).statusCode).toBe(200);
  });

  it('uses cached releases unless refresh is explicitly requested', async () => {
    await app.inject({ method: 'GET', url: base + '/9/releases' });
    await app.inject({ method: 'GET', url: base + '/9/releases?refresh=true' });
    await app.inject({ method: 'GET', url: base + '/9/releases?refresh=false' });
    expect(fulfillment.listReleases.mock.calls).toEqual([
      [9, { refresh: false }],
      [9, { refresh: true }],
      [9, { refresh: false }],
    ]);
  });

  it('forwards search overrides and selected release identifiers without accepting download URLs', async () => {
    const search = { title: 'Dune', authors: ['Frank Herbert'], isbn: '9780441172719', language: 'en', preferredFormats: ['epub'] };
    await app.inject({ method: 'POST', url: base + '/9/releases/search', payload: search });
    expect(fulfillment.listReleases).toHaveBeenCalledWith(9, { refresh: true, overrides: search });
    const picked = { indexerId: 3, releaseGuid: 'release-guid' };
    await app.inject({ method: 'POST', url: base + '/9/releases/inspect', payload: picked });
    expect(fulfillment.inspectRelease).toHaveBeenCalledExactlyOnceWith(9, picked);
    const grab = { ...picked, downloadClientId: 4, holdForReview: true };
    await app.inject({ method: 'POST', url: base + '/9/grab', payload: grab });
    expect(fulfillment.grab).toHaveBeenCalledExactlyOnceWith(9, grab, user);
  });

  it('uses the download-client summary projection and returns no administrative configuration', async () => {
    downloadClients.findAll.mockResolvedValue([{ id: 4, baseUrl: 'https://private.test', password: 'secret', credentialsEnc: 'encrypted-secret' }]);
    const response = await app.inject({ method: 'GET', url: base + '/9/download-clients' });
    expect(downloadClients.findEnabledSummaries).toHaveBeenCalledExactlyOnceWith();
    expect(downloadClients.findAll).not.toHaveBeenCalled();
    expect(response.json()).toEqual([{ id: 4, name: 'Library downloads', color: null, delivery: 'torrent' }]);
  });

  it('returns the review and rereads state only after held-import actions finish', async () => {
    const review = await app.inject({ method: 'GET', url: base + '/9/review' });
    expect(review.json()).toMatchObject({ status: 'needs_review' });
    expect(verification.getReview).toHaveBeenCalledExactlyOnceWith(9);
    for (const [path, action] of [
      ['force-file', verification.fileHeldImport],
      ['discard-import', verification.discardHeldImport],
    ] as const) {
      requests.getOne.mockClear();
      action.mockImplementationOnce(() => {
        expect(requests.getOne).not.toHaveBeenCalled();
        return Promise.resolve();
      });
      const response = await app.inject({ method: 'POST', url: base + '/9/' + path });
      expect(response.json()).toEqual(settled);
      expect(action).toHaveBeenCalledExactlyOnceWith(9, user);
      expect(requests.getOne).toHaveBeenCalledExactlyOnceWith(9, user);
    }
  });

  it('selects a stored release unit by index and rereads the canonical request', async () => {
    imports.importChosenUnit.mockImplementationOnce(() => {
      expect(requests.getOne).not.toHaveBeenCalled();
      return Promise.resolve();
    });
    const response = await app.inject({ method: 'POST', url: base + '/9/downloads/12/select-unit', payload: { unitIndex: '2' } });
    expect(imports.importChosenUnit).toHaveBeenCalledExactlyOnceWith(9, 12, 2);
    expect(requests.getOne).toHaveBeenCalledExactlyOnceWith(9, user);
    expect(response.json()).toEqual(settled);
  });

  it.each(['/9/force-file', '/9/discard-import', '/9/downloads/12/select-unit'])('awaits the import action before rereading %s', async (path) => {
    const action = path.endsWith('/force-file')
      ? verification.fileHeldImport
      : path.endsWith('/discard-import')
        ? verification.discardHeldImport
        : imports.importChosenUnit;
    let finish!: () => void;
    let reached!: () => void;
    const started = new Promise<void>((resolve) => {
      reached = resolve;
    });
    action.mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          finish = resolve;
          reached();
        }),
    );
    const response = app
      .inject({ method: 'POST', url: base + path, payload: path.endsWith('/select-unit') ? { unitIndex: 0 } : undefined })
      .then((result) => result);
    await started;
    expect(requests.getOne).not.toHaveBeenCalled();
    finish();
    expect((await response).json()).toEqual(settled);
    expect(requests.getOne).toHaveBeenCalledExactlyOnceWith(9, user);
  });

  it('cancels only the named download attempt as the authenticated user', async () => {
    const response = await app.inject({ method: 'POST', url: base + '/9/downloads/12/cancel' });
    expect(requests.cancelDownload).toHaveBeenCalledExactlyOnceWith(9, 12, user);
    expect(response.json()).toEqual({ id: 9, status: 'approved' });
  });

  it.each([
    ['/9/releases/search', { title: 'x'.repeat(501) }],
    ['/9/releases/search', { authors: 'not-an-array' }],
    ['/9/releases/search', { preferredFormats: new Array(21).fill('epub') }],
    ['/9/releases/search', { downloadUrl: 'https://attacker.test/release' }],
    ['/9/releases/inspect', { indexerId: 0, releaseGuid: 'guid' }],
    ['/9/releases/inspect', { indexerId: 3 }],
    ['/9/releases/inspect', { indexerId: 3, releaseGuid: 'guid', downloadUrl: 'http://127.0.0.1/private' }],
    ['/9/grab', { indexerId: -1, releaseGuid: 'guid' }],
    ['/9/grab', { indexerId: 3, releaseGuid: 'guid', downloadClientId: 0 }],
    ['/9/grab', { indexerId: 3, releaseGuid: 'guid', holdForReview: 'yes' }],
    ['/9/grab', { indexerId: 3, releaseGuid: 'guid', url: 'http://127.0.0.1/private' }],
    ['/9/downloads/12/select-unit', {}],
    ['/9/downloads/12/select-unit', { unitIndex: -1 }],
    ['/9/downloads/12/select-unit', { unitIndex: 1.5 }],
    ['/9/downloads/12/select-unit', { unitIndex: 0, path: '/private/book.epub' }],
  ])('rejects invalid DTO fields at %s', async (path, payload) => {
    const response = await app.inject({ method: 'POST', url: base + path, payload });
    expect(response.statusCode).toBe(400);
    expect(requests.assertCanFulfil).not.toHaveBeenCalled();
    expect(downstream().every((mock) => mock.mock.calls.length === 0)).toBe(true);
  });

  it.each(['/not-an-id/releases', '/9/releases?refresh=perhaps', '/9/downloads/not-an-id/cancel'])(
    'rejects malformed path/query values at %s',
    async (path) => {
      const response = await app.inject({ method: path.endsWith('/cancel') ? 'POST' : 'GET', url: base + path });
      expect(response.statusCode).toBe(400);
      expect(requests.assertCanFulfil).not.toHaveBeenCalled();
    },
  );

  it('preserves service validation errors without publishing a fake success', async () => {
    fulfillment.grab.mockRejectedValueOnce(new BadRequestException('Pick exactly one release'));
    const response = await app.inject({ method: 'POST', url: base + '/9/grab', payload: {} });
    expect(response.statusCode).toBe(400);
    expect(response.json().message).toBe('Pick exactly one release');
    verification.fileHeldImport.mockRejectedValueOnce(new BadRequestException('No held import'));
    expect((await app.inject({ method: 'POST', url: base + '/9/force-file' })).statusCode).toBe(400);
    expect(requests.getOne).not.toHaveBeenCalled();
  });

  it.each([
    ['grab', AuditAction.BookRequestGrab],
    ['forceFile', AuditAction.BookRequestImport],
    ['discardImport', AuditAction.BookRequestImport],
    ['selectReleaseUnit', AuditAction.BookRequestImport],
    ['cancelDownload', AuditAction.BookRequestRemoveDownload],
  ] as const)('keeps audit metadata on %s', (method, action) => {
    const metadata = Reflect.getMetadata(AUDITABLE_KEY, KoreaderRequestFulfilmentController.prototype[method]) as AuditableOptions;
    expect(metadata).toMatchObject({ action, resource: AuditResource.BookRequest });
    expect(metadata.getResourceId?.({ params: { id: '9' } } as never, undefined)).toBe(9);
    expect(metadata.description).toBeTruthy();
  });
});
